#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s /absolute/path/to/test.env\n' "$0" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

config_file=$1
if [[ ! -r "$config_file" ]]; then
  printf 'Configuration file is not readable: %s\n' "$config_file" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$config_file"

: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"
: "${CSK_ENDPOINT:?CSK_ENDPOINT is required}"
: "${CSK_PORT:=3306}"
: "${CSK_PREFIX:=cskaws}"
: "${CSK_SLEEP_SECONDS:=30}"
: "${CSK_DISCOVERY_SECONDS:=10}"
: "${CSK_KEEP_OBJECTS:=0}"

if [[ ! -r "$CSK_ADMIN_CNF" ]]; then
  printf 'Admin option file is not readable: %s\n' "$CSK_ADMIN_CNF" >&2
  exit 2
fi
if [[ "$CSK_PREFIX" =~ [^A-Za-z0-9_] ]] || (( ${#CSK_PREFIX} > 12 )); then
  printf 'CSK_PREFIX must match [A-Za-z0-9_]{1,12}\n' >&2
  exit 2
fi
if [[ ! "$CSK_PORT" =~ ^[0-9]+$ ]] ||
   [[ ! "$CSK_SLEEP_SECONDS" =~ ^[0-9]+$ ]] ||
   [[ ! "$CSK_DISCOVERY_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'Port and timeout settings must be positive integers\n' >&2
  exit 2
fi
if (( CSK_SLEEP_SECONDS < 10 || CSK_DISCOVERY_SECONDS < 2 )); then
  printf 'CSK_SLEEP_SECONDS must be >= 10 and CSK_DISCOVERY_SECONDS >= 2\n' >&2
  exit 2
fi

for dependency in mysql openssl awk sed grep date; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Missing dependency: %s\n' "$dependency" >&2
    exit 2
  fi
done

if [[ -z "${CSK_TEST_PASSWORD:-}" ]]; then
  CSK_TEST_PASSWORD=$(openssl rand -hex 18)
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/$run_id"
mkdir -p "$result_dir/targets" "$result_dir/metadata"

db_name="${CSK_PREFIX}_db"
user_u0="${CSK_PREFIX}_u0"
user_ue="${CSK_PREFIX}_ue"
user_up="${CSK_PREFIX}_up"
user_ur="${CSK_PREFIX}_ur"
user_t1="${CSK_PREFIX}_t1"
user_same="${CSK_PREFIX}_same"

admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --skip-column-names --connect-timeout=10)
test_mysql=(mysql --host="$CSK_ENDPOINT" --port="$CSK_PORT"
  --ssl-mode=REQUIRED --batch --raw --skip-column-names --connect-timeout=10)

cases_file="$result_dir/cases.tsv"
events_file="$result_dir/events.log"
printf 'case_id\tcaller\tprocedure\ttarget_user\tcall_rc\ttarget_rc\ttarget_alive\ttarget_id\terror\n' >"$cases_file"

active_pids=()
cleanup_started=0
START_PID=''
START_ID=''

log_event() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$events_file"
}

admin_sql() {
  "${admin_mysql[@]}" --execute="$1"
}

user_sql() {
  local account=$1
  local sql=$2
  MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$account" --execute="$sql"
}

sql_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\'\'}
  printf '%s' "$value"
}

record_command() {
  local name=$1
  shift
  local output_file="$result_dir/metadata/$name.txt"
  local rc
  set +e
  "$@" >"$output_file" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\n' "$name" "$rc" >>"$result_dir/metadata/status.tsv"
  return 0
}

cleanup_objects() {
  if (( cleanup_started == 1 )); then
    return
  fi
  cleanup_started=1

  for pid in "${active_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done

  if [[ "$CSK_KEEP_OBJECTS" == "1" ]]; then
    log_event "Leaving test objects because CSK_KEEP_OBJECTS=1"
    return
  fi

  log_event "Cleaning disposable test users and database"
  admin_sql "DROP USER IF EXISTS
    '$user_u0'@'%', '$user_ue'@'%', '$user_up'@'%', '$user_ur'@'%',
    '$user_t1'@'%', '$user_same'@'%';
    DROP DATABASE IF EXISTS \`$db_name\`;" >>"$events_file" 2>&1 || true
}

trap cleanup_objects EXIT INT TERM

forget_pid() {
  local finished_pid=$1
  local index
  for index in "${!active_pids[@]}"; do
    if [[ "${active_pids[$index]}" == "$finished_pid" ]]; then
      unset "active_pids[$index]"
      return
    fi
  done
}

start_target() {
  local case_id=$1
  local target_user=$2
  local target_log="$result_dir/targets/${case_id}.log"
  local marker="${CSK_PREFIX}_${case_id}"
  local lookup_user=$target_user
  START_PID=''
  START_ID=''

  if [[ "$target_user" == MASTER ]]; then
    lookup_user=$master_user
    "${admin_mysql[@]}" --force --execute="SELECT CONNECTION_ID() AS target_id;
        SELECT SLEEP($CSK_SLEEP_SECONDS) AS $marker;
        SELECT 'target_connection_alive';" >"$target_log" 2>&1 &
  else
    MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$target_user" \
      --force --execute="SELECT CONNECTION_ID() AS target_id;
        SELECT SLEEP($CSK_SLEEP_SECONDS) AS $marker;
        SELECT 'target_connection_alive';" >"$target_log" 2>&1 &
  fi
  local pid=$!
  active_pids+=("$pid")

  local target_id=''
  local attempt
  for ((attempt=0; attempt<CSK_DISCOVERY_SECONDS*5; attempt++)); do
    target_id=$(admin_sql "SELECT ID FROM information_schema.processlist
      WHERE USER='$lookup_user' AND INFO LIKE 'SELECT SLEEP(%'
      ORDER BY ID DESC LIMIT 1;" 2>/dev/null || true)
    target_id=${target_id//$'\r'/}
    target_id=${target_id//$'\n'/}
    if [[ "$target_id" =~ ^[0-9]+$ ]]; then
      START_PID=$pid
      START_ID=$target_id
      return 0
    fi
    sleep 0.2
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  forget_pid "$pid"
  printf 'Could not discover target for %s\n' "$case_id" >&2
  return 1
}

invoke_as() {
  local caller=$1
  local sql=$2
  if [[ "$caller" == MASTER ]]; then
    admin_sql "$sql"
  else
    user_sql "$caller" "$sql"
  fi
}

run_kill_case() {
  local case_id=$1
  local caller=$2
  local procedure=$3
  local target_user=$4
  local session_prefix=${5:-}
  local target_pid
  local target_id
  local call_log="$result_dir/${case_id}.call.log"
  local call_rc target_rc target_alive error_text

  log_event "Running $case_id caller=$caller procedure=$procedure target=$target_user"
  if ! start_target "$case_id" "$target_user"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$case_id" "$caller" "$procedure" "$target_user" 125 125 no unknown \
      'target discovery failed' >>"$cases_file"
    return 0
  fi
  target_pid=$START_PID
  target_id=$START_ID

  set +e
  invoke_as "$caller" "$session_prefix CALL mysql.$procedure($target_id);" \
    >"$call_log" 2>&1
  call_rc=$?
  set -e

  # A denied call cannot affect the target. Close only the local disposable
  # client so authorization probes do not wait for the full SLEEP duration.
  if (( call_rc != 0 )) && kill -0 "$target_pid" 2>/dev/null; then
    kill "$target_pid" 2>/dev/null || true
  fi

  set +e
  wait "$target_pid"
  target_rc=$?
  set -e
  forget_pid "$target_pid"

  if grep -q 'target_connection_alive' "$result_dir/targets/${case_id}.log"; then
    target_alive=yes
  else
    target_alive=no
  fi
  error_text=$(tr '\t\r\n' '   ' <"$call_log" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  [[ -n "$error_text" ]] || error_text='-'

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_id" "$caller" "$procedure" "$target_user" "$call_rc" \
    "$target_rc" "$target_alive" "$target_id" "$error_text" >>"$cases_file"
}

run_direct_case() {
  local case_id=$1
  local caller=$2
  local procedure=$3
  local argument=$4
  local call_log="$result_dir/${case_id}.call.log"
  local call_rc error_text

  log_event "Running $case_id caller=$caller procedure=$procedure argument=$argument"
  set +e
  invoke_as "$caller" "CALL mysql.$procedure($argument);" >"$call_log" 2>&1
  call_rc=$?
  set -e
  error_text=$(tr '\t\r\n' '   ' <"$call_log" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  [[ -n "$error_text" ]] || error_text='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_id" "$caller" "$procedure" '-' "$call_rc" '-' n/a '-' \
    "$error_text" >>"$cases_file"
}

write_report() {
  local report="$result_dir/report.md"
  {
    printf '# AWS RDS for MySQL session-kill probe\n\n'
    printf -- '- Run ID: `%s`\n' "$run_id"
    printf -- '- Endpoint: `%s:%s`\n' "$CSK_ENDPOINT" "$CSK_PORT"
    printf -- '- Prefix: `%s`\n' "$CSK_PREFIX"
    printf -- '- Raw cases: `cases.tsv`\n\n'
    printf '## Observations\n\n'
    printf '| Case | Caller | Procedure | Target | Call RC | Target RC | Target alive | Target ID | Error/output |\n'
    printf '|---|---|---|---|---:|---:|---|---:|---|\n'
    awk -F '\t' 'NR > 1 {
      gsub(/\|/, "\\|", $9);
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",
             $1,$2,$3,$4,$5,$6,$7,$8,$9
    }' "$cases_file"
    printf '\n## Interpretation status\n\n'
    printf 'This file is an automatically collected evidence summary. '\
           'A final conclusion must correlate metadata, GRANT results, call results, '\
           'target logs, engine version, and AWS documentation.\n'
  } >"$report"
}

log_event "Checking connectivity and capturing baseline"
admin_sql "SELECT 1;" >/dev/null
master_user=$(admin_sql "SELECT SUBSTRING_INDEX(CURRENT_USER(), '@', 1);")
if [[ -z "$master_user" ]]; then
  printf 'Could not determine the authenticated master user\n' >&2
  exit 2
fi

printf 'name\trc\n' >"$result_dir/metadata/status.tsv"
record_command instance "${admin_mysql[@]}" --execute="SELECT VERSION(), @@version_comment, @@hostname;"
record_command identity "${admin_mysql[@]}" --execute="SELECT USER(), CURRENT_USER(), CURRENT_ROLE(), CONNECTION_ID(); SHOW GRANTS;"
record_command routines "${admin_mysql[@]}" --execute="SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, DEFINER, SECURITY_TYPE, SQL_DATA_ACCESS, ROUTINE_COMMENT FROM information_schema.routines WHERE ROUTINE_SCHEMA='mysql' AND ROUTINE_NAME IN ('rds_kill','rds_kill_query') ORDER BY ROUTINE_NAME;"
record_command create_rds_kill "${admin_mysql[@]}" --execute="SHOW CREATE PROCEDURE mysql.rds_kill;"
record_command create_rds_kill_query "${admin_mysql[@]}" --execute="SHOW CREATE PROCEDURE mysql.rds_kill_query;"
record_command routine_grants "${admin_mysql[@]}" --execute="SELECT USER, HOST, DB, ROUTINE_NAME, ROUTINE_TYPE, GRANTOR, PROC_PRIV FROM mysql.procs_priv WHERE DB='mysql' AND ROUTINE_NAME IN ('rds_kill','rds_kill_query');"
record_command superuser_role "${admin_mysql[@]}" --execute="SHOW GRANTS FOR rds_superuser_role@'%';"

escaped_password=$(sql_escape "$CSK_TEST_PASSWORD")
log_event "Creating disposable users"
admin_sql "CREATE DATABASE IF NOT EXISTS \`$db_name\`;
  CREATE TABLE IF NOT EXISTS \`$db_name\`.probe(id BIGINT PRIMARY KEY, note VARCHAR(64));
  DROP USER IF EXISTS
    '$user_u0'@'%', '$user_ue'@'%', '$user_up'@'%', '$user_ur'@'%',
    '$user_t1'@'%', '$user_same'@'%';
  CREATE USER '$user_u0'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_ue'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_up'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_ur'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_t1'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_same'@'%' IDENTIFIED BY '$escaped_password';
  GRANT SELECT, INSERT, UPDATE, DELETE ON \`$db_name\`.* TO
    '$user_u0'@'%', '$user_ue'@'%', '$user_up'@'%', '$user_ur'@'%',
    '$user_t1'@'%', '$user_same'@'%';"

record_command grant_process "${admin_mysql[@]}" --execute="GRANT PROCESS ON *.* TO '$user_up'@'%';"
record_command grant_execute_kill "${admin_mysql[@]}" --execute="GRANT EXECUTE ON PROCEDURE mysql.rds_kill TO '$user_ue'@'%';"
record_command grant_execute_query "${admin_mysql[@]}" --execute="GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$user_ue'@'%';"
record_command grant_rds_role "${admin_mysql[@]}" --execute="GRANT rds_superuser_role@'%' TO '$user_ur'@'%';"

for account in "$user_u0" "$user_ue" "$user_up" "$user_ur"; do
  safe_name=${account//[^A-Za-z0-9_]/_}
  record_command "grants_$safe_name" env MYSQL_PWD="$CSK_TEST_PASSWORD" \
    "${test_mysql[@]}" --user="$account" \
    --execute="SELECT USER(), CURRENT_USER(), CURRENT_ROLE(); SHOW GRANTS;"
done

# Authorization matrix. Each case uses a new target connection owned only by a
# disposable account.
run_kill_case AUTH_1_MASTER MASTER rds_kill_query "$user_t1"
run_kill_case AUTH_2_ORDINARY "$user_u0" rds_kill_query "$user_t1"
run_kill_case AUTH_3_PROCESS "$user_up" rds_kill_query "$user_t1"
run_kill_case AUTH_4_EXECUTE "$user_ue" rds_kill_query "$user_t1"
run_kill_case AUTH_5_EXECUTE_SESSION "$user_ue" rds_kill "$user_t1"
run_kill_case AUTH_6_ROLE_NONE "$user_ur" rds_kill_query "$user_t1" 'SET ROLE NONE;'
run_kill_case AUTH_7_ROLE_ALL "$user_ur" rds_kill_query "$user_t1" 'SET ROLE ALL;'

# Procedure semantics and target scope with the documented master user.
run_kill_case SCOPE_2_SAME_ACCOUNT MASTER rds_kill_query MASTER
run_kill_case SCOPE_2B_SAME_SESSION MASTER rds_kill MASTER
run_kill_case SCOPE_3_CROSS_ACCOUNT MASTER rds_kill_query "$user_same"
run_kill_case SEM_1_QUERY MASTER rds_kill_query "$user_t1"
run_kill_case SEM_2_SESSION MASTER rds_kill "$user_t1"

# Invalid values cannot identify a real target and are safe to exercise on an
# otherwise empty disposable instance.
run_direct_case PARAM_NULL MASTER rds_kill_query NULL
run_direct_case PARAM_ZERO MASTER rds_kill_query 0
run_direct_case PARAM_NEGATIVE MASTER rds_kill_query -1
run_direct_case PARAM_DECIMAL MASTER rds_kill_query 1.5
run_direct_case PARAM_TEXT MASTER rds_kill_query "'not-a-thread-id'"
run_direct_case PARAM_OVERFLOW MASTER rds_kill_query 4294967296

# Revoke should affect a subsequent invocation. The GRANT/REVOKE operations are
# separately captured because RDS may reject delegation itself.
record_command revoke_execute_query "${admin_mysql[@]}" --execute="REVOKE EXECUTE ON PROCEDURE mysql.rds_kill_query FROM '$user_ue'@'%';"
run_kill_case LIFE_2_REVOKE "$user_ue" rds_kill_query "$user_t1"
record_command revoke_rds_role "${admin_mysql[@]}" --execute="REVOKE rds_superuser_role@'%' FROM '$user_ur'@'%';"
run_kill_case LIFE_4_ROLE_REVOKE "$user_ur" rds_kill_query "$user_t1" 'SET ROLE ALL;'

write_report
log_event "Evidence collected in $result_dir"

if [[ "$CSK_KEEP_OBJECTS" != "1" ]]; then
  cleanup_objects
fi
trap - EXIT INT TERM
"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"

