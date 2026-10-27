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
: "${CSK_TEST_PASSWORD:=}"
: "${CSK_DISCOVERY_SECONDS:=10}"
: "${CSK_SLEEP_SECONDS:=30}"
: "${CSK_KEEP_OBJECTS:=1}"

if [[ "$CSK_PREFIX" =~ [^A-Za-z0-9_] ]] || (( ${#CSK_PREFIX} > 12 )); then
  printf 'CSK_PREFIX must match [A-Za-z0-9_]{1,12}\n' >&2
  exit 2
fi

for dependency in mysql openssl awk sed grep mkfifo date; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'Missing dependency: %s\n' "$dependency" >&2
    exit 2
  }
done

if [[ -z "$CSK_TEST_PASSWORD" ]]; then
  CSK_TEST_PASSWORD=$(openssl rand -hex 18)
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
result_dir="$script_dir/results/${run_id}-deep-semantics"
mkdir -p "$result_dir/targets" "$result_dir/lifecycle" "$result_dir/transactions"

db_name="${CSK_PREFIX}_db"
user_life="${CSK_PREFIX}_life"
user_exec="${CSK_PREFIX}_dx"
user_target="${CSK_PREFIX}_dt"
user_process="${CSK_PREFIX}_dp"
user_role="${CSK_PREFIX}_dr"

admin_mysql=(mysql --defaults-extra-file="$CSK_ADMIN_CNF"
  --batch --raw --skip-column-names --unbuffered --skip-reconnect
  --connect-timeout=10)
test_mysql=(mysql --host="$CSK_ENDPOINT" --port="$CSK_PORT"
  --ssl-mode=REQUIRED --batch --raw --skip-column-names --unbuffered
  --skip-reconnect --connect-timeout=10)

events="$result_dir/events.log"
status="$result_dir/status.tsv"
printf 'case_id\tcategory\trc\tevidence\n' >"$status"

active_pids=()
pc_pid=''
pc_fifo=''
pc_log=''
pc_fd_open=0
cleanup_started=0
TARGET_PID=''
TARGET_ID=''
TARGET_LOG=''
WAITER_PID=''
WAITER_ID=''
WAITER_LOG=''

log_event() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$events"
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

flatten() {
  tr '\t\r\n' '   ' <"$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

record() {
  local case_id=$1
  local category=$2
  local rc=$3
  local file=$4
  local evidence
  evidence=$(flatten "$file")
  [[ -n "$evidence" ]] || evidence='-'
  evidence=${evidence//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$case_id" "$category" "$rc" "$evidence" >>"$status"
}

capture() {
  local case_id=$1
  local category=$2
  shift 2
  local file="$result_dir/${case_id}.log"
  local rc
  set +e
  "$@" >"$file" 2>&1
  rc=$?
  set -e
  record "$case_id" "$category" "$rc" "$file"
}

wait_for_pattern() {
  local file=$1
  local pattern=$2
  local attempt
  for ((attempt=0; attempt<CSK_DISCOVERY_SECONDS*10; attempt++)); do
    if grep -Fq "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  printf 'Timed out waiting for %s in %s\n' "$pattern" "$file" >&2
  return 1
}

stop_persistent() {
  if (( pc_fd_open == 1 )); then
    printf 'quit\n' >&9 2>/dev/null || true
    exec 9>&-
    pc_fd_open=0
  fi
  if [[ -n "$pc_pid" ]]; then
    wait "$pc_pid" 2>/dev/null || true
    pc_pid=''
  fi
  if [[ -n "$pc_fifo" ]]; then
    rm -f "$pc_fifo"
    pc_fifo=''
  fi
}

start_persistent() {
  local account=$1
  local name=$2
  stop_persistent
  pc_fifo="$result_dir/${name}.fifo"
  pc_log="$result_dir/${name}.log"
  rm -f "$pc_fifo"
  mkfifo "$pc_fifo"
  if [[ "$account" == MASTER ]]; then
    "${admin_mysql[@]}" --force <"$pc_fifo" >"$pc_log" 2>&1 &
  else
    MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$account" \
      --force <"$pc_fifo" >"$pc_log" 2>&1 &
  fi
  pc_pid=$!
  active_pids+=("$pc_pid")
  exec 9>"$pc_fifo"
  pc_fd_open=1
  printf "SELECT 'READY_%s', CONNECTION_ID(), USER(), CURRENT_USER(), CURRENT_ROLE();\n" "$name" >&9
  wait_for_pattern "$pc_log" "READY_$name"
}

persistent_step() {
  local marker=$1
  local sql=$2
  printf "SELECT 'BEGIN_%s'; %s SELECT 'END_%s';\n" "$marker" "$sql" "$marker" >&9
  wait_for_pattern "$pc_log" "END_$marker"
}

persistent_id() {
  local name=$1
  awk -v marker="READY_$name" '$1 == marker {print $2; exit}' "$pc_log"
}

start_sleep_target() {
  local case_id=$1
  local account=$2
  local role_prefix=${3:-}
  local lookup_user=$account
  TARGET_LOG="$result_dir/targets/${case_id}.log"
  if [[ "$account" == MASTER ]]; then
    lookup_user=$master_user
    "${admin_mysql[@]}" --force --execute="SELECT CONNECTION_ID();
      SELECT SLEEP($CSK_SLEEP_SECONDS); SELECT 'TARGET_CONNECTION_ALIVE';" \
      >"$TARGET_LOG" 2>&1 &
  else
    MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$account" \
      --force --execute="$role_prefix SELECT CONNECTION_ID();
        SELECT SLEEP($CSK_SLEEP_SECONDS); SELECT 'TARGET_CONNECTION_ALIVE';" \
      >"$TARGET_LOG" 2>&1 &
  fi
  TARGET_PID=$!
  active_pids+=("$TARGET_PID")
  TARGET_ID=''
  local attempt
  for ((attempt=0; attempt<CSK_DISCOVERY_SECONDS*10; attempt++)); do
    TARGET_ID=$(admin_sql "SELECT ID FROM information_schema.processlist
      WHERE USER='$lookup_user' AND INFO LIKE 'SELECT SLEEP(%'
      ORDER BY ID DESC LIMIT 1;" 2>/dev/null || true)
    TARGET_ID=${TARGET_ID//$'\r'/}
    TARGET_ID=${TARGET_ID//$'\n'/}
    [[ "$TARGET_ID" =~ ^[0-9]+$ ]] && return 0
    sleep 0.1
  done
  kill "$TARGET_PID" 2>/dev/null || true
  wait "$TARGET_PID" 2>/dev/null || true
  return 1
}

run_target_case() {
  local case_id=$1
  local caller=$2
  local procedure=$3
  local target=$4
  local target_prefix=${5:-}
  local call_file="$result_dir/${case_id}.log"
  local rc target_rc
  if ! start_sleep_target "$case_id" "$target" "$target_prefix"; then
    printf '%s\ttarget-matrix\t125\ttarget discovery failed\n' "$case_id" >>"$status"
    return
  fi
  set +e
  if [[ "$caller" == MASTER ]]; then
    admin_sql "CALL mysql.$procedure($TARGET_ID);" >"$call_file" 2>&1
  else
    user_sql "$caller" "CALL mysql.$procedure($TARGET_ID);" >"$call_file" 2>&1
  fi
  rc=$?
  wait "$TARGET_PID"
  target_rc=$?
  set -e
  printf 'target_id=%s target_rc=%s target_alive=%s\n' "$TARGET_ID" "$target_rc" \
    "$(grep -q TARGET_CONNECTION_ALIVE "$TARGET_LOG" && printf yes || printf no)" >>"$call_file"
  record "$case_id" target-matrix "$rc" "$call_file"
}

start_lock_waiter() {
  local case_id=$1
  local row_id=$2
  local new_value=$3
  WAITER_LOG="$result_dir/transactions/${case_id}.log"
  MYSQL_PWD="$CSK_TEST_PASSWORD" "${test_mysql[@]}" --user="$user_exec" --force \
    --execute="SET SESSION innodb_lock_wait_timeout=20; START TRANSACTION;
      UPDATE \`$db_name\`.deep_lock_probe SET value=$new_value WHERE id=$row_id;
      SELECT 'WAITER_CONNECTION_ALIVE'; ROLLBACK;" >"$WAITER_LOG" 2>&1 &
  WAITER_PID=$!
  active_pids+=("$WAITER_PID")
  WAITER_ID=''
  local attempt
  for ((attempt=0; attempt<CSK_DISCOVERY_SECONDS*10; attempt++)); do
    WAITER_ID=$(admin_sql "SELECT ID FROM information_schema.processlist
      WHERE USER='$user_exec' AND INFO LIKE 'UPDATE %deep_lock_probe%'
      ORDER BY ID DESC LIMIT 1;" 2>/dev/null || true)
    WAITER_ID=${WAITER_ID//$'\r'/}
    WAITER_ID=${WAITER_ID//$'\n'/}
    [[ "$WAITER_ID" =~ ^[0-9]+$ ]] && return 0
    sleep 0.1
  done
  return 1
}

cleanup() {
  if (( cleanup_started == 1 )); then
    return
  fi
  cleanup_started=1
  stop_persistent
  local pid
  for pid in "${active_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ "$CSK_KEEP_OBJECTS" != "1" ]]; then
    admin_sql "DROP USER IF EXISTS '$user_life'@'%', '$user_exec'@'%',
      '$user_target'@'%', '$user_process'@'%', '$user_role'@'%';
      DROP TABLE IF EXISTS \`$db_name\`.deep_lock_probe;" >>"$events" 2>&1 || true
  else
    log_event "Leaving deep-test users/table because CSK_KEEP_OBJECTS=1"
  fi
}
trap cleanup EXIT INT TERM

escaped_password=$(sql_escape "$CSK_TEST_PASSWORD")
log_event 'Preparing isolated deep-test accounts and lock table'
admin_sql "CREATE DATABASE IF NOT EXISTS \`$db_name\`;
  CREATE TABLE IF NOT EXISTS \`$db_name\`.deep_lock_probe(
    id INT PRIMARY KEY, value INT NOT NULL) ENGINE=InnoDB;
  INSERT INTO \`$db_name\`.deep_lock_probe VALUES(1,0),(2,0)
    ON DUPLICATE KEY UPDATE value=0;
  DROP USER IF EXISTS '$user_life'@'%', '$user_exec'@'%',
    '$user_target'@'%', '$user_process'@'%', '$user_role'@'%';
  CREATE USER '$user_life'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_exec'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_target'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_process'@'%' IDENTIFIED BY '$escaped_password';
  CREATE USER '$user_role'@'%' IDENTIFIED BY '$escaped_password';
  GRANT SELECT,INSERT,UPDATE,DELETE ON \`$db_name\`.* TO
    '$user_life'@'%', '$user_exec'@'%', '$user_target'@'%',
    '$user_process'@'%', '$user_role'@'%';
  GRANT PROCESS ON *.* TO '$user_process'@'%';
  GRANT EXECUTE ON PROCEDURE mysql.rds_kill TO '$user_exec'@'%';
  GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$user_exec'@'%';
  GRANT rds_superuser_role@'%' TO '$user_role'@'%';"
master_user=$(admin_sql "SELECT SUBSTRING_INDEX(CURRENT_USER(), '@', 1);")

# LIFE: all calls below run over the same TCP connection. Unknown-thread 1094
# proves that routine authorization succeeded without touching a real target.
log_event 'Testing GRANT and REVOKE on one persistent connection'
start_persistent "$user_life" life_execute
persistent_step LIFE_EXEC_BEFORE "CALL mysql.rds_kill_query(0);"
admin_sql "GRANT EXECUTE ON PROCEDURE mysql.rds_kill_query TO '$user_life'@'%';"
persistent_step LIFE_EXEC_AFTER_GRANT "CALL mysql.rds_kill_query(0);"
admin_sql "REVOKE EXECUTE ON PROCEDURE mysql.rds_kill_query FROM '$user_life'@'%';"
persistent_step LIFE_EXEC_AFTER_REVOKE "CALL mysql.rds_kill_query(0);"
stop_persistent
record LIFE_EXEC_PERSISTENT lifecycle 0 "$result_dir/life_execute.log"
capture LIFE_EXEC_NEW_CONNECTION lifecycle user_sql "$user_life" \
  "CALL mysql.rds_kill_query(0);"

log_event 'Testing active role revocation on one persistent connection'
start_persistent "$user_role" life_role
persistent_step LIFE_ROLE_ACTIVE \
  "SET ROLE rds_superuser_role; SELECT CURRENT_ROLE(); CALL mysql.rds_kill_query(0);"
admin_sql "REVOKE rds_superuser_role@'%' FROM '$user_role'@'%';"
persistent_step LIFE_ROLE_AFTER_REVOKE \
  "SELECT CURRENT_ROLE(); CALL mysql.rds_kill_query(0);"
stop_persistent
record LIFE_ROLE_PERSISTENT lifecycle 0 "$result_dir/life_role.log"
capture LIFE_ROLE_NEW_CONNECTION lifecycle user_sql "$user_role" \
  "SET ROLE ALL; SELECT CURRENT_ROLE(); CALL mysql.rds_kill_query(0);"

# Complete two-routine authorization symmetry using nonexistent thread 0.
log_event 'Testing both routines for each caller authorization state'
capture AUTH_ORDINARY_QUERY authorization user_sql "$user_life" \
  "CALL mysql.rds_kill_query(0);"
capture AUTH_ORDINARY_SESSION authorization user_sql "$user_life" \
  "CALL mysql.rds_kill(0);"
capture AUTH_PROCESS_QUERY authorization user_sql "$user_process" \
  "CALL mysql.rds_kill_query(0);"
capture AUTH_PROCESS_SESSION authorization user_sql "$user_process" \
  "CALL mysql.rds_kill(0);"
capture AUTH_EXECUTE_QUERY authorization user_sql "$user_exec" \
  "CALL mysql.rds_kill_query(0);"
capture AUTH_EXECUTE_SESSION authorization user_sql "$user_exec" \
  "CALL mysql.rds_kill(0);"
admin_sql "GRANT rds_superuser_role@'%' TO '$user_role'@'%';"
capture AUTH_ROLE_NONE_QUERY authorization user_sql "$user_role" \
  "SET ROLE NONE; CALL mysql.rds_kill_query(0);"
capture AUTH_ROLE_NONE_SESSION authorization user_sql "$user_role" \
  "SET ROLE NONE; CALL mysql.rds_kill(0);"
capture AUTH_ROLE_ACTIVE_QUERY authorization user_sql "$user_role" \
  "SET ROLE rds_superuser_role; CALL mysql.rds_kill_query(0);"
capture AUTH_ROLE_ACTIVE_SESSION authorization user_sql "$user_role" \
  "SET ROLE rds_superuser_role; CALL mysql.rds_kill(0);"

# SELF: query kill should leave the connection usable; session kill is expected
# to disconnect before the END marker can be printed.
log_event 'Testing true self-kill with CONNECTION_ID()'
start_persistent "$user_exec" self_query
persistent_step SELF_QUERY \
  "CALL mysql.rds_kill_query(CONNECTION_ID()); SELECT 'SELF_QUERY_CONNECTION_ALIVE';"
stop_persistent
record SELF_QUERY self 0 "$result_dir/self_query.log"

start_persistent "$user_exec" self_session
self_session_id=$(persistent_id self_session)
printf "SELECT 'BEGIN_SELF_SESSION'; CALL mysql.rds_kill(CONNECTION_ID()); SELECT 'SELF_SESSION_CONNECTION_ALIVE'; SELECT 'END_SELF_SESSION';\n" >&9
sleep 3
self_session_count=$(admin_sql "SELECT COUNT(*) FROM information_schema.processlist WHERE ID=$self_session_id;")
printf 'ORIGINAL_CONNECTION_ID=%s PROCESSLIST_COUNT_AFTER=%s\n' \
  "$self_session_id" "$self_session_count" >>"$pc_log"
stop_persistent
record SELF_SESSION self 0 "$result_dir/self_session.log"

# IDLE: KILL QUERY against a Sleep connection must not be confused with a
# connection kill. The next command is sent on the same target connection.
log_event 'Testing KILL QUERY against an idle connection'
start_persistent "$user_target" idle_target
idle_id=$(persistent_id idle_target)
capture IDLE_QUERY_CALL semantics admin_sql "CALL mysql.rds_kill_query($idle_id);"
persistent_step IDLE_QUERY_AFTERMATH "SELECT 'IDLE_CONNECTION_ALIVE', CONNECTION_ID();"
stop_persistent
record IDLE_QUERY_TARGET semantics 0 "$result_dir/idle_target.log"

# TRANSACTION: after KILL QUERY, the same transaction should still own its row
# lock. A second connection is expected to time out until the target rolls back.
log_event 'Testing KILL QUERY transaction and row-lock aftermath'
start_persistent "$user_target" tx_query_target
tx_query_id=$(persistent_id tx_query_target)
printf "SET SESSION innodb_lock_wait_timeout=3; START TRANSACTION; UPDATE \`%s\`.deep_lock_probe SET value=11 WHERE id=1; SELECT 'TXQ_LOCKED'; SELECT SLEEP(%s); SELECT 'TXQ_SLEEP_FINISHED';\n" \
  "$db_name" "$CSK_SLEEP_SECONDS" >&9
wait_for_pattern "$pc_log" TXQ_LOCKED
capture TX_QUERY_KILL semantics admin_sql "CALL mysql.rds_kill_query($tx_query_id);"
persistent_step TX_QUERY_VALUE \
  "SELECT value FROM \`$db_name\`.deep_lock_probe WHERE id=1;"
capture TX_QUERY_STATE_ADMIN transaction admin_sql \
  "SELECT trx_mysql_thread_id,trx_state,trx_started,trx_rows_locked,trx_rows_modified
     FROM information_schema.innodb_trx
    WHERE trx_mysql_thread_id=$tx_query_id;"
capture TX_QUERY_LOCK_HELD transaction user_sql "$user_exec" \
  "SET SESSION innodb_lock_wait_timeout=2; UPDATE \`$db_name\`.deep_lock_probe SET value=12 WHERE id=1;"
persistent_step TX_QUERY_ROLLBACK "ROLLBACK; SELECT 'TX_ROLLED_BACK';"
capture TX_QUERY_LOCK_RELEASED transaction user_sql "$user_exec" \
  "UPDATE \`$db_name\`.deep_lock_probe SET value=13 WHERE id=1;"
stop_persistent
record TX_QUERY_TARGET transaction 0 "$result_dir/tx_query_target.log"

# KILL CONNECTION must roll back the uncommitted update and release the lock.
log_event 'Testing KILL CONNECTION rollback and lock release'
admin_sql "UPDATE \`$db_name\`.deep_lock_probe SET value=0 WHERE id=2;"
start_persistent "$user_target" tx_session_target
tx_session_id=$(persistent_id tx_session_target)
printf "START TRANSACTION; UPDATE \`%s\`.deep_lock_probe SET value=21 WHERE id=2; SELECT 'TXS_LOCKED'; SELECT SLEEP(%s);\n" \
  "$db_name" "$CSK_SLEEP_SECONDS" >&9
wait_for_pattern "$pc_log" TXS_LOCKED
capture TX_SESSION_KILL semantics admin_sql "CALL mysql.rds_kill($tx_session_id);"
sleep 1
stop_persistent
capture TX_SESSION_ROLLBACK transaction admin_sql \
  "SELECT value FROM \`$db_name\`.deep_lock_probe WHERE id=2; UPDATE \`$db_name\`.deep_lock_probe SET value=22 WHERE id=2; SELECT value FROM \`$db_name\`.deep_lock_probe WHERE id=2;"
record TX_SESSION_TARGET transaction 0 "$result_dir/tx_session_target.log"

# LOCK WAIT: terminate the blocked UPDATE itself, once with QUERY and once with
# CONNECTION, while proving the independent lock holder remains usable.
log_event 'Testing a row-lock waiter as the direct target'
for procedure in rds_kill_query rds_kill; do
  admin_sql "UPDATE \`$db_name\`.deep_lock_probe SET value=0 WHERE id=1;"
  start_persistent "$user_target" "lock_holder_$procedure"
  printf "START TRANSACTION; UPDATE \`%s\`.deep_lock_probe SET value=31 WHERE id=1; SELECT 'HOLDER_LOCKED_%s';\n" \
    "$db_name" "$procedure" >&9
  wait_for_pattern "$pc_log" "HOLDER_LOCKED_$procedure"
  if start_lock_waiter "LOCK_WAITER_$procedure" 1 32; then
    capture "LOCK_WAITER_${procedure}_CALL" lock-wait admin_sql \
      "CALL mysql.$procedure($WAITER_ID);"
    set +e
    wait "$WAITER_PID"
    waiter_rc=$?
    set -e
    printf 'waiter_id=%s waiter_rc=%s\n' "$WAITER_ID" "$waiter_rc" >>"$WAITER_LOG"
    record "LOCK_WAITER_${procedure}_TARGET" lock-wait "$waiter_rc" "$WAITER_LOG"
  else
    printf 'LOCK_WAITER_%s\tlock-wait\t125\twaiter discovery failed\n' \
      "$procedure" >>"$status"
  fi
  persistent_step "HOLDER_AFTER_$procedure" \
    "SELECT 'HOLDER_STILL_ALIVE'; ROLLBACK;"
  stop_persistent
done

# TARGET MATRIX: every protected routine is exercised against the same target
# categories. The role-holder target activates its role before sleeping.
log_event 'Testing complete target matrix for both procedures'
for procedure in rds_kill_query rds_kill; do
  run_target_case "SCOPE_${procedure}_SAME_ACCOUNT" "$user_exec" "$procedure" "$user_exec"
  run_target_case "SCOPE_${procedure}_ORDINARY" "$user_exec" "$procedure" "$user_target"
  run_target_case "SCOPE_${procedure}_PROCESS" "$user_exec" "$procedure" "$user_process"
  admin_sql "GRANT rds_superuser_role@'%' TO '$user_role'@'%';"
  run_target_case "SCOPE_${procedure}_ROLE_TARGET" "$user_exec" "$procedure" "$user_role" \
    'SET ROLE rds_superuser_role;'
  run_target_case "SCOPE_${procedure}_MASTER_TARGET" "$user_exec" "$procedure" MASTER
done

# Visibility is checked before the kill. The caller has routine EXECUTE but no
# PROCESS, so a zero count plus successful call proves the permissions differ.
log_event 'Testing process visibility separately from kill authority'
start_sleep_target VISIBILITY_KNOWN_ID "$user_target"
capture VISIBILITY_WITHOUT_PROCESS visibility user_sql "$user_exec" \
  "SELECT COUNT(*) FROM information_schema.processlist WHERE ID=$TARGET_ID;"
capture VISIBILITY_KNOWN_ID_KILL visibility user_sql "$user_exec" \
  "CALL mysql.rds_kill_query($TARGET_ID);"
set +e
wait "$TARGET_PID"
visibility_target_rc=$?
set -e
printf 'target_id=%s target_rc=%s\n' "$TARGET_ID" "$visibility_target_rc" \
  >>"$result_dir/VISIBILITY_KNOWN_ID_KILL.log"

# Native KILL is a separate authority path and must be recorded independently.
log_event 'Testing native KILL authorization baseline'
start_persistent "$user_target" native_target_u0
native_id=$(persistent_id native_target_u0)
capture NATIVE_U0_QUERY native-kill user_sql "$user_life" "KILL QUERY $native_id;"
capture NATIVE_PROCESS_QUERY native-kill user_sql "$user_process" "KILL QUERY $native_id;"
capture NATIVE_EXECUTE_QUERY native-kill user_sql "$user_exec" "KILL QUERY $native_id;"
capture NATIVE_MASTER_QUERY native-kill admin_sql "KILL QUERY $native_id;"
persistent_step NATIVE_TARGET_ALIVE "SELECT 'NATIVE_TARGET_ALIVE';"
capture NATIVE_MASTER_CONNECTION native-kill admin_sql "KILL CONNECTION $native_id;"
sleep 1
stop_persistent
record NATIVE_TARGET native-kill 0 "$result_dir/native_target_u0.log"

# RACE: two authorized callers target one query concurrently. One may observe
# an already-finished/nonexistent query, but neither may affect another thread.
log_event 'Testing two concurrent killers against one target'
start_sleep_target RACE_TWO_KILLERS "$user_target"
admin_sql "CALL mysql.rds_kill_query($TARGET_ID);" >"$result_dir/RACE_KILLER_1.log" 2>&1 &
race_pid_1=$!
admin_sql "CALL mysql.rds_kill_query($TARGET_ID);" >"$result_dir/RACE_KILLER_2.log" 2>&1 &
race_pid_2=$!
set +e
wait "$race_pid_1"; race_rc_1=$?
wait "$race_pid_2"; race_rc_2=$?
wait "$TARGET_PID"; race_target_rc=$?
set -e
printf 'killer_1_rc=%s killer_2_rc=%s target_rc=%s target_id=%s\n' \
  "$race_rc_1" "$race_rc_2" "$race_target_rc" "$TARGET_ID" \
  >"$result_dir/RACE_TWO_KILLERS.log"
record RACE_TWO_KILLERS race 0 "$result_dir/RACE_TWO_KILLERS.log"

# Both procedures use the same declared BIGINT input but are tested separately
# so differences in coercion or procedure bodies remain visible.
log_event 'Testing parameter conversion matrix for both procedures'
parameters=(
  'NULL'
  '0'
  '-1'
  '1.5'
  "'123'"
  "' 123 '"
  "'1e2'"
  "'abc'"
  '4294967295'
  '4294967296'
  'CONNECTION_ID()'
)
for procedure in rds_kill_query rds_kill; do
  index=0
  for argument in "${parameters[@]}"; do
    index=$((index + 1))
    capture "PARAM_${procedure}_${index}" parameter admin_sql \
      "CALL mysql.$procedure($argument);"
  done
  capture "PARAM_${procedure}_PREPARED" parameter admin_sql \
    "SET @thread_arg='0'; PREPARE csk_stmt FROM 'CALL mysql.$procedure(?)'; EXECUTE csk_stmt USING @thread_arg; DEALLOCATE PREPARE csk_stmt;"
done

cat >"$result_dir/report.md" <<EOF
# AWS RDS MySQL deep session-kill evidence

- Run ID: \`$run_id\`
- Endpoint: \`$CSK_ENDPOINT:$CSK_PORT\`
- Raw status: \`status.tsv\`

This run covers persistent-session GRANT/REVOKE, active-role revocation, true
self-kill, idle targets, transaction/lock aftermath, native KILL separation,
and the two-procedure parameter matrix. Errors are evidence: in particular,
1094 means routine execution was authorized but the thread did not exist,
while 1370 means EXECUTE was denied.

AWS reserved/internal sessions were not targeted.
EOF

log_event "Deep evidence collected in $result_dir"
cleanup
trap - EXIT INT TERM
"$script_dir/collect-results.sh" "$result_dir" >/dev/null
printf '%s\n' "$result_dir"
