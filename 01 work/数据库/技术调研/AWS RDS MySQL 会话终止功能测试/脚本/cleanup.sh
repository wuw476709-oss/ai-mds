#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s /absolute/path/to/test.env\n' "$0" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$1"
: "${CSK_ADMIN_CNF:?CSK_ADMIN_CNF is required}"
: "${CSK_PREFIX:=cskaws}"

if [[ "$CSK_PREFIX" =~ [^A-Za-z0-9_] ]] || (( ${#CSK_PREFIX} > 12 )); then
  printf 'Invalid CSK_PREFIX\n' >&2
  exit 2
fi

db_name="${CSK_PREFIX}_db"
users=(u0 ue up ur t1 same life dx dt dp dr g1 g2 g3 r1 r2 r3)
drop_sql='DROP USER IF EXISTS '
separator=''
for suffix in "${users[@]}"; do
  drop_sql+="${separator}'${CSK_PREFIX}_${suffix}'@'%'"
  separator=', '
done
drop_sql+=';'
drop_sql+=" DROP TABLE IF EXISTS \`$db_name\`.deep_lock_probe;"
drop_sql+=" DROP DATABASE IF EXISTS \`$db_name\`;"

mysql --defaults-extra-file="$CSK_ADMIN_CNF" --execute="$drop_sql"
printf 'Removed disposable objects with prefix %s\n' "$CSK_PREFIX"

