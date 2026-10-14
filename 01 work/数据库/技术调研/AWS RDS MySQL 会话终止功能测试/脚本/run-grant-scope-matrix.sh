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
: "${CSK_KEEP_FINAL_PROCEDURE_CHAIN:=0}"

if [[ "$CSK_PREFIX" =~ [^A-Za-z0-9_] ]] || (( ${#CSK_PREFIX} > 12 )); then
  printf 'CSK_PREFIX must match [A-Za-z0-9_]{1,12}\n' >&2
  exit 2
fi
if [[ -z "$CSK_TEST_PASSWORD" ]]; then
  CSK_TEST_PASSWORD=$(openssl rand -hex 18)
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-grant-scope-matrix"
mkdir -p "$result_dir"
status="$result_dir/status.tsv"
printf 'case_id\trc\n' >"$status"

g1="${CSK_PREFIX}_g1"
g2="${CSK_PREFIX}_g2"
g3="${CSK_PREFIX}_g3"

admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --connect-timeout=10)
test_mysql=(mysql --host="$CSK_ENDPOINT" --port="$CSK_PORT"
  --ssl-mode=REQUIRED --batch --raw --connect-timeout=10)

admin_sql() { "${admin_mysql[@]}" --execute="$1"; }
user_sql() {
  local account=$1 sql=$2
  MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$account" --execute="$sql"
}
sql_escape() {
  local value=$1
  value=${value//\\/\\\\}; value=${value//\'/\'\'}
  printf '%s' "$value"
}
capture() {
  local case_id=$1
  shift
  local rc
  set +e
  "$@" >"$result_dir/${case_id}.log" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\n' "$case_id" "$rc" >>"$status"
}

cleanup_privileges() {
  set +e
  for account in "$g1" "$g2" "$g3"; do
    admin_sql "REVOKE GRANT OPTION ON *.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON *.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE GRANT OPTION ON mysql.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON mysql.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON PROCEDURE mysql.rds_kill FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON PROCEDURE mysql.rds_kill_query FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE GRANT OPTION ON PROCEDURE mysql.rds_kill FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE GRANT OPTION ON PROCEDURE mysql.rds_kill_query FROM '$account'@'%';" >/dev/null 2>&1
  done
  set -e
}

cleanup_broad_privileges() {
  set +e
  for account in "$g1" "$g2" "$g3"; do
    admin_sql "REVOKE GRANT OPTION ON *.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON *.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE GRANT OPTION ON mysql.* FROM '$account'@'%';" >/dev/null 2>&1
    admin_sql "REVOKE EXECUTE ON mysql.* FROM '$account'@'%';" >/dev/null 2>&1
  done
  set -e
}

cleanup() {
  # Global and mysql.* EXECUTE/GRANT OPTION are never retained. The only
  # optionally retained capability is the final rds_kill_query procedure chain.
  cleanup_broad_privileges
  if [[ "$CSK_KEEP_FINAL_PROCEDURE_CHAIN" != "1" ]]; then
    cleanup_privileges
  fi
  if [[ "$CSK_KEEP_OBJECTS" != "1" ]]; then
    admin_sql "DROP USER IF EXISTS '$g1'@'%', '$g2'@'%', '$g3'@'%';" \
      >>"$result_dir/cleanup.log" 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

escaped_password=$(sql_escape "$CSK_TEST_PASSWORD")
admin_sql "DROP USER IF EXISTS '$g1'@'%', '$g2'@'%', '$g3'@'%';
  CREATE USER '$g1'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$g2'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$g3'@'%' IDENTIFIED BY '$escaped_password';"

# Global scope: usage covers both routines. Delegation follows GRANT OPTION.
capture GLOBAL_GRANT_NO_GO admin_sql "GRANT EXECUTE ON *.* TO '$g1'@'%';"
capture GLOBAL_CALL_QUERY user_sql "$g1" "CALL mysql.rds_kill_query(0);"
capture GLOBAL_CALL_SESSION user_sql "$g1" "CALL mysql.rds_kill(0);"
capture GLOBAL_REGRANT_NO_GO user_sql "$g1" "GRANT EXECUTE ON *.* TO '$g2'@'%';"
cleanup_privileges

capture GLOBAL_GRANT_WITH_GO admin_sql \
  "GRANT EXECUTE ON *.* TO '$g1'@'%' WITH GRANT OPTION;"
capture GLOBAL_CHAIN_G1_G2 user_sql "$g1" \
  "GRANT EXECUTE ON *.* TO '$g2'@'%' WITH GRANT OPTION;"
capture GLOBAL_CHAIN_G2_G3 user_sql "$g2" \
  "GRANT EXECUTE ON *.* TO '$g3'@'%';"
capture GLOBAL_REVOKE_UPSTREAM admin_sql \
  "REVOKE GRANT OPTION ON *.* FROM '$g1'@'%'; REVOKE EXECUTE ON *.* FROM '$g1'@'%';"
capture GLOBAL_DOWNSTREAM_AFTER_REVOKE user_sql "$g3" \
  "CALL mysql.rds_kill_query(0);"
cleanup_privileges

# Database scope: mysql.* should cover both routines in mysql, not other DBs.
capture DATABASE_GRANT_NO_GO admin_sql "GRANT EXECUTE ON mysql.* TO '$g1'@'%';"
capture DATABASE_CALL_QUERY user_sql "$g1" "CALL mysql.rds_kill_query(0);"
capture DATABASE_CALL_SESSION user_sql "$g1" "CALL mysql.rds_kill(0);"
capture DATABASE_REGRANT_NO_GO user_sql "$g1" \
  "GRANT EXECUTE ON mysql.* TO '$g2'@'%';"
cleanup_privileges

capture DATABASE_GRANT_WITH_GO admin_sql \
  "GRANT EXECUTE ON mysql.* TO '$g1'@'%' WITH GRANT OPTION;"
capture DATABASE_CHAIN_G1_G2 user_sql "$g1" \
  "GRANT EXECUTE ON mysql.* TO '$g2'@'%' WITH GRANT OPTION;"
capture DATABASE_CHAIN_G2_G3 user_sql "$g2" \
  "GRANT EXECUTE ON mysql.* TO '$g3'@'%';"
capture DATABASE_REVOKE_UPSTREAM admin_sql \
  "REVOKE GRANT OPTION ON mysql.* FROM '$g1'@'%'; REVOKE EXECUTE ON mysql.* FROM '$g1'@'%';"
capture DATABASE_DOWNSTREAM_AFTER_REVOKE user_sql "$g3" \
  "CALL mysql.rds_kill(0);"
cleanup_privileges

# Procedure scope: privileges and delegation must remain isolated per routine.
capture PROCEDURE_GRANT_NO_GO admin_sql \
  "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$g1'@'%';"
capture PROCEDURE_ALLOWED_QUERY user_sql "$g1" "CALL mysql.rds_kill_query(0);"
capture PROCEDURE_DENIED_SESSION user_sql "$g1" "CALL mysql.rds_kill(0);"
capture PROCEDURE_REGRANT_NO_GO user_sql "$g1" \
  "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$g2'@'%';"
cleanup_privileges

capture PROCEDURE_GRANT_WITH_GO admin_sql \
  "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$g1'@'%' WITH GRANT OPTION;"
capture PROCEDURE_CHAIN_G1_G2 user_sql "$g1" \
  "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$g2'@'%' WITH GRANT OPTION;"
capture PROCEDURE_CHAIN_G2_G3 user_sql "$g2" \
  "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$g3'@'%';"
capture PROCEDURE_REVOKE_UPSTREAM admin_sql \
  "REVOKE GRANT OPTION ON PROCEDURE mysql.rds_kill_query FROM '$g1'@'%';
   REVOKE EXECUTE ON PROCEDURE mysql.rds_kill_query FROM '$g1'@'%';"
capture PROCEDURE_DOWNSTREAM_AFTER_REVOKE user_sql "$g3" \
  "CALL mysql.rds_kill_query(0);"
capture PROCEDURE_DOWNSTREAM_OTHER_DENIED user_sql "$g3" \
  "CALL mysql.rds_kill(0);"

for account in "$g1" "$g2" "$g3"; do
  safe=${account//[^A-Za-z0-9_]/_}
  capture "FINAL_GRANTS_$safe" admin_sql "SHOW GRANTS FOR '$account'@'%';"
done

cat >"$result_dir/report.md" <<EOF
# AWS RDS MySQL EXECUTE grant-scope evidence

- Run ID: \`$run_id\`
- Scopes: global, database (\`mysql.*\`), procedure
- Each scope: without/with GRANT OPTION, multi-hop delegation, and upstream
  revocation with downstream-retention check
- Both RDS kill procedures are checked for scope isolation

An expected \`ERROR 1094\` proves routine entry; \`ERROR 1370\` proves denial.
Review \`status.tsv\`, individual logs, and final grants together.
EOF

cleanup
trap - EXIT INT TERM
"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"
