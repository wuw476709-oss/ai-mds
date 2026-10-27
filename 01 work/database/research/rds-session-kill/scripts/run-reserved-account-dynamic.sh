#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ! -r "$1" ]]; then
  printf 'Usage: %s /absolute/path/to/test.env\n' "$0" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$1"
: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-reserved-dynamic"
mkdir -p "$result_dir"
admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --skip-column-names --connect-timeout=10)

admin_sql() { "${admin_mysql[@]}" --execute="$1"; }
capture() {
  local name=$1; shift
  local rc
  set +e
  "$@" >"$result_dir/$name.log" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\n' "$name" "$rc" >>"$result_dir/status.tsv"
  return 0
}

printf 'case_id\trc\n' >"$result_dir/status.tsv"

capture reserved_users admin_sql \
  "SELECT user,host FROM mysql.rds_reserved_users ORDER BY user,host;"
capture reserved_processes_before admin_sql \
  "SELECT p.ID,p.USER,p.HOST,p.COMMAND,p.TIME,p.STATE
     FROM information_schema.processlist p
     JOIN mysql.rds_reserved_users r
       ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST)
    ORDER BY p.USER,p.ID;"

target_id=$(admin_sql "SELECT p.ID
  FROM information_schema.processlist p
  JOIN mysql.rds_reserved_users r
    ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST)
 WHERE p.USER='rdsadmin' AND p.COMMAND='Sleep'
 ORDER BY p.TIME DESC,p.ID
 LIMIT 1;")
target_id=${target_id//$'\r'/}
target_id=${target_id//$'\n'/}
if [[ ! "$target_id" =~ ^[0-9]+$ ]]; then
  printf 'No exact reserved rdsadmin Sleep target was available\n' \
    >"$result_dir/NOT_EXECUTED.log"
  "$script_dir/collect-results.sh" "$result_dir" >/dev/null
  printf '%s\n' "$result_dir"
  exit 3
fi
printf '%s\n' "$target_id" >"$result_dir/target_id.txt"

capture rds_kill_query_reserved admin_sql \
  "CALL mysql.rds_kill_query($target_id);"

capture reserved_target_after_query admin_sql \
  "SELECT ID,USER,HOST,COMMAND,TIME,STATE
     FROM information_schema.processlist WHERE ID=$target_id;"
capture reserved_processes_after admin_sql \
  "SELECT p.ID,p.USER,p.HOST,p.COMMAND,p.TIME,p.STATE
     FROM information_schema.processlist p
     JOIN mysql.rds_reserved_users r
       ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST)
    ORDER BY p.USER,p.ID;"

if grep -Eiq 'CANNOT KILL[[:space:]]+rdsadmin[[:space:]]+SESSION' \
    "$result_dir/rds_kill_query_reserved.log"; then
  printf 'PASS: query procedure rejected the reserved target\n' \
    >"$result_dir/query_guard_result.txt"
else
  printf 'UNEXPECTED: query procedure did not return the reserved-target rejection\n' \
    >"$result_dir/query_guard_result.txt"
fi

"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"
