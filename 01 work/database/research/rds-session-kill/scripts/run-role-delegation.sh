#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ! -r "$1" ]]; then
  printf 'Usage: %s /absolute/path/to/test.env\n' "$0" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$1"
: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"
: "${CSK_ENDPOINT:?CSK_ENDPOINT is required}"
: "${CSK_PORT:=3306}"
: "${CSK_PREFIX:=cskaws}"
: "${CSK_TEST_PASSWORD:=}"
: "${CSK_KEEP_OBJECTS:=1}"
[[ -n "$CSK_TEST_PASSWORD" ]] || CSK_TEST_PASSWORD=$(openssl rand -hex 18)

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-role-delegation"
mkdir -p "$result_dir"
status="$result_dir/status.tsv"
printf 'case_id\trc\n' >"$status"

r1="${CSK_PREFIX}_r1"; r2="${CSK_PREFIX}_r2"; r3="${CSK_PREFIX}_r3"
admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF" --batch --raw --connect-timeout=10)
test_mysql=(mysql --host="$CSK_ENDPOINT" --port="$CSK_PORT" --ssl-mode=REQUIRED --batch --raw --connect-timeout=10)
admin_sql() { "${admin_mysql[@]}" --execute="$1"; }
user_sql() { local u=$1 q=$2; MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$u" --execute="$q"; }
capture() {
  local id=$1; shift
  local rc
  set +e; "$@" >"$result_dir/$id.log" 2>&1; rc=$?; set -e
  printf '%s\t%s\n' "$id" "$rc" >>"$status"
}
sql_escape() { local v=$1; v=${v//\\/\\\\}; v=${v//\'/\'\'}; printf '%s' "$v"; }
cleanup_roles() {
  set +e
  for u in "$r1" "$r2" "$r3"; do
    admin_sql "REVOKE rds_superuser_role@'%' FROM '$u'@'%';" >/dev/null 2>&1
  done
  set -e
}
cleanup() {
  cleanup_roles
  if [[ "$CSK_KEEP_OBJECTS" != 1 ]]; then
    admin_sql "DROP USER IF EXISTS '$r1'@'%', '$r2'@'%', '$r3'@'%';" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

pw=$(sql_escape "$CSK_TEST_PASSWORD")
admin_sql "DROP USER IF EXISTS '$r1'@'%', '$r2'@'%', '$r3'@'%';
  CREATE USER '$r1'@'%' IDENTIFIED BY '$pw';
  CREATE USER '$r2'@'%' IDENTIFIED BY '$pw';
  CREATE USER '$r3'@'%' IDENTIFIED BY '$pw';"

capture ROLE_GRANT_NO_ADMIN admin_sql "GRANT rds_superuser_role@'%' TO '$r1'@'%';"
capture ROLE_REGRANT_NO_ADMIN user_sql "$r1" "GRANT rds_superuser_role@'%' TO '$r2'@'%';"
cleanup_roles

capture ROLE_GRANT_WITH_ADMIN admin_sql \
  "GRANT rds_superuser_role@'%' TO '$r1'@'%' WITH ADMIN OPTION;"
capture ROLE_CHAIN_R1_R2 user_sql "$r1" \
  "GRANT rds_superuser_role@'%' TO '$r2'@'%' WITH ADMIN OPTION;"
capture ROLE_CHAIN_R2_R3 user_sql "$r2" \
  "GRANT rds_superuser_role@'%' TO '$r3'@'%';"
capture ROLE_R3_CALL user_sql "$r3" \
  "SET ROLE rds_superuser_role; SELECT CURRENT_ROLE(); CALL mysql.rds_kill_query(0);"
capture ROLE_REVOKE_UPSTREAM admin_sql "REVOKE rds_superuser_role@'%' FROM '$r1'@'%';"
capture ROLE_R3_AFTER_UPSTREAM_REVOKE user_sql "$r3" \
  "SET ROLE rds_superuser_role; SELECT CURRENT_ROLE(); CALL mysql.rds_kill_query(0);"
for u in "$r1" "$r2" "$r3"; do
  capture "GRANTS_$u" admin_sql "SHOW GRANTS FOR '$u'@'%';"
done

cleanup
trap - EXIT INT TERM
"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"
