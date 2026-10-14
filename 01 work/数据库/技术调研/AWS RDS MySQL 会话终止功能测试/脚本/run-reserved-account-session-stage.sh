#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 || ! -r "$1" || ! -d "$2" ]]; then
  printf 'Usage: %s /absolute/path/to/test.env /absolute/path/to/query-stage-result\n' "$0" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$1"
: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"

prior_dir=$(cd "$2" && pwd)
prior_log="$prior_dir/rds_kill_query_reserved.log"
prior_id_file="$prior_dir/target_id.txt"
if [[ ! -r "$prior_log" || ! -r "$prior_id_file" ]]; then
  printf 'Prior query-stage evidence is incomplete\n' >&2
  exit 2
fi
if ! grep -Eiq 'ERROR 1644 .*CANNOT KILL[[:space:]]+rdsadmin[[:space:]]+SESSION' "$prior_log"; then
  printf 'Prior query stage did not prove the reserved-account rejection\n' >&2
  exit 3
fi

target_id=$(tr -d '\r\n' <"$prior_id_file")
[[ "$target_id" =~ ^[0-9]+$ ]] || {
  printf 'Invalid target id in prior evidence\n' >&2
  exit 2
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-reserved-session-stage"
mkdir -p "$result_dir"
admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --skip-column-names --connect-timeout=10)
admin_sql() { "${admin_mysql[@]}" --execute="$1"; }
capture() {
  local name=$1; shift
  local rc
  set +e; "$@" >"$result_dir/$name.log" 2>&1; rc=$?; set -e
  printf '%s\t%s\n' "$name" "$rc" >>"$result_dir/status.tsv"
}
printf 'case_id\trc\n' >"$result_dir/status.tsv"
printf '%s\n' "$target_id" >"$result_dir/target_id.txt"
printf '%s\n' "$prior_dir" >"$result_dir/prior_query_stage.txt"

capture target_before admin_sql \
  "SELECT p.ID,p.USER,p.HOST,p.COMMAND,p.TIME,p.STATE
     FROM information_schema.processlist p
     JOIN mysql.rds_reserved_users r
       ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST)
    WHERE p.ID=$target_id;"

safe_count=$(admin_sql "SELECT COUNT(*)
  FROM information_schema.processlist p
  JOIN mysql.rds_reserved_users r
    ON r.user=p.USER AND (r.host='%' OR r.host=p.HOST)
 WHERE p.ID=$target_id AND p.USER='rdsadmin' AND p.COMMAND='Sleep';")
if [[ "$safe_count" != 1 ]]; then
  printf 'NOT EXECUTED: target is no longer the same idle reserved rdsadmin session\n' \
    >"$result_dir/SAFETY_STOP.txt"
  "$script_dir/collect-results.sh" "$result_dir" >/dev/null
  printf '%s\n' "$result_dir"
  exit 4
fi

capture rds_kill_reserved admin_sql "CALL mysql.rds_kill($target_id);"
capture target_after admin_sql \
  "SELECT ID,USER,HOST,COMMAND,TIME,STATE
     FROM information_schema.processlist WHERE ID=$target_id;"

"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"
