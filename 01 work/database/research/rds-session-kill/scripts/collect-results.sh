#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  printf 'Usage: %s /absolute/path/to/result-directory\n' "$0" >&2
  exit 2
fi

result_dir=$(cd "$1" && pwd)
output_dir="$result_dir/raw-mysql"
mkdir -p "$output_dir"

manifest="$output_dir/manifest.tsv"
combined="$output_dir/mysql-output.log"
errors="$output_dir/mysql-errors.tsv"
files_list="$output_dir/files.list"

# Do not feed generated bundles back into themselves on a repeated collection.
find "$result_dir" -type f \
  ! -path "$output_dir/*" \
  \( -name '*.log' -o -name '*.txt' -o -name '*.tsv' -o -name '*.sql' \) \
  -print | LC_ALL=C sort >"$files_list"

printf 'relative_path\tbytes\tcksum\n' >"$manifest"
: >"$combined"
printf 'relative_path\tline\tmessage\n' >"$errors"

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  relative=${file#"$result_dir"/}
  bytes=$(wc -c <"$file" | tr -d '[:space:]')
  checksum=$(cksum "$file" | awk '{print $1 ":" $2}')
  printf '%s\t%s\t%s\n' "$relative" "$bytes" "$checksum" >>"$manifest"

  printf '\n===== BEGIN %s =====\n' "$relative" >>"$combined"
  cat "$file" >>"$combined"
  printf '\n===== END %s =====\n' "$relative" >>"$combined"

  awk -v path="$relative" '
    /(^|[[:space:]])(ERROR|WARNING)[[:space:]]/ {
      message=$0
      gsub(/\t/, " ", message)
      printf "%s\t%d\t%s\n", path, NR, message
    }
  ' "$file" >>"$errors"
done <"$files_list"

printf '%s\n' "$output_dir"
