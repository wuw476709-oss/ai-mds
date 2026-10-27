#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s /absolute/path/to/test.env\n' "$0" >&2
}

if [[ $# -ne 1 || ! -r "$1" ]]; then
  usage
  exit 2
fi

# shellcheck disable=SC1090
source "$1"

: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"
: "${CSK_ENDPOINT:?CSK_ENDPOINT is required}"
: "${CSK_PORT:=3306}"
: "${CSK_PREFIX:=cskaws}"
: "${CSK_TEST_PASSWORD:?CSK_TEST_PASSWORD is required}"

if [[ "$CSK_PREFIX" =~ [^A-Za-z0-9_] ]] || (( ${#CSK_PREFIX} > 12 )); then
  printf 'CSK_PREFIX must match [A-Za-z0-9_]{1,12}\n' >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-grant-reserved-boundaries"
mkdir -p "$result_dir"

user_grantor="${CSK_PREFIX}_ue"
user_recipient="${CSK_PREFIX}_u0"
user_downstream="${CSK_PREFIX}_same"

admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --connect-timeout=10)
test_mysql=(mysql --host="$CSK_ENDPOINT" --port="$CSK_PORT"
  --ssl-mode=REQUIRED --batch --raw --connect-timeout=10)

admin_sql() {
  "${admin_mysql[@]}" --execute="$1"
}

user_sql() {
  local account=$1
  local sql=$2
  MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" \
    --user="$account" --execute="$sql"
}

capture() {
  local name=$1
  shift
  local rc
  set +e
  "$@" >"$result_dir/$name.log" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\n' "$name" "$rc" | tee -a "$result_dir/status.tsv"
  return 0
}

cleanup_global_execute() {
  set +e
  for account in "$user_grantor" "$user_recipient" "$user_downstream"; do
    admin_sql "REVOKE GRANT OPTION ON *.* FROM '$account'@'%';" \
      >>"$result_dir/cleanup.log" 2>&1
    admin_sql "REVOKE EXECUTE ON *.* FROM '$account'@'%';" \
      >>"$result_dir/cleanup.log" 2>&1
  done
  set -e
}

trap cleanup_global_execute EXIT
printf 'case\trc\n' >"$result_dir/status.tsv"

# These are dedicated test accounts. Remove only global EXECUTE left by an
# interrupted earlier run; procedure-level grants are not affected.
cleanup_global_execute

capture baseline_grants_grantor admin_sql \
  "SHOW GRANTS FOR '$user_grantor'@'%';"
capture baseline_grants_recipient admin_sql \
  "SHOW GRANTS FOR '$user_recipient'@'%';"

# A. Global EXECUTE without GRANT OPTION must allow use, but not delegation.
capture grant_global_execute_without_grant_option admin_sql \
  "GRANT EXECUTE ON *.* TO '$user_grantor'@'%';"
capture grants_without_grant_option admin_sql \
  "SHOW GRANTS FOR '$user_grantor'@'%';"
capture call_with_global_execute user_sql "$user_grantor" \
  "CALL mysql.rds_kill_query(0);"
capture regrant_without_grant_option user_sql "$user_grantor" \
  "GRANT EXECUTE ON *.* TO '$user_recipient'@'%';"
capture recipient_after_failed_regrant admin_sql \
  "SHOW GRANTS FOR '$user_recipient'@'%';"

cleanup_global_execute

# B. Repeat with GRANT OPTION to learn whether RDS adds a private anti-delegation
# restriction beyond ordinary MySQL privilege semantics.
capture grant_global_execute_with_grant_option admin_sql \
  "GRANT EXECUTE ON *.* TO '$user_grantor'@'%' WITH GRANT OPTION;"
capture grants_with_grant_option admin_sql \
  "SHOW GRANTS FOR '$user_grantor'@'%';"
capture regrant_with_grant_option user_sql "$user_grantor" \
  "GRANT EXECUTE ON *.* TO '$user_recipient'@'%';"
capture recipient_after_successful_regrant admin_sql \
  "SHOW GRANTS FOR '$user_recipient'@'%';"
capture recipient_call_after_regrant user_sql "$user_recipient" \
  "CALL mysql.rds_kill_query(0);"
capture recipient_cannot_delegate user_sql "$user_recipient" \
  "GRANT EXECUTE ON *.* TO '$user_downstream'@'%';"

# C. Reserved-account protection is inspected read-only. Never issue KILL
# against an AWS internal thread from this probe.
capture reserved_users admin_sql \
  "SELECT * FROM mysql.rds_reserved_users ORDER BY user, host;"
capture reserved_processes admin_sql \
  "SELECT p.ID,p.USER,p.HOST,p.COMMAND,p.STATE,r.user AS reserved_user,r.host AS reserved_host FROM information_schema.processlist AS p JOIN mysql.rds_reserved_users AS r ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST) ORDER BY p.ID;"
capture create_rds_kill admin_sql \
  "SHOW CREATE PROCEDURE mysql.rds_kill;"
capture create_rds_kill_query admin_sql \
  "SHOW CREATE PROCEDURE mysql.rds_kill_query;"

cleanup_global_execute
trap - EXIT

capture final_grants_grantor admin_sql \
  "SHOW GRANTS FOR '$user_grantor'@'%';"
capture final_grants_recipient admin_sql \
  "SHOW GRANTS FOR '$user_recipient'@'%';"
capture final_grants_downstream admin_sql \
  "SHOW GRANTS FOR '$user_downstream'@'%';"

"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf 'Results: %s\n' "$result_dir"
