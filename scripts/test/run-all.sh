#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-ci}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci@example.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-ci}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci@example.com}"

usage() {
  echo "usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)" >&2
  exit 2
}

shard_given=0
shard_value=""
list_mode=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shard)
      [ "$shard_given" -eq 1 ] && usage
      [ "$#" -lt 2 ] && usage
      shard_given=1
      shard_value=$2
      shift 2
      ;;
    --list)
      [ "$list_mode" -eq 1 ] && usage
      list_mode=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# If the flag was not given, fall back to the environment — but only then.
# The flag path above never inspects YSTACK_TEST_SHARD at all: its shape,
# range and even its existence are irrelevant once --shard was given.
if [ "$shard_given" -eq 0 ] && [ "${YSTACK_TEST_SHARD+x}" = x ]; then
  shard_value="$YSTACK_TEST_SHARD"
  shard_given=1
fi

index=0
count=0
if [ "$shard_given" -eq 1 ]; then
  # Cap the numeric shape (at most two digits each, no leading zero) before
  # any arithmetic or `[ -le ]`: count is bounded at 16 by the spec, so two
  # digits suffice, and a value this short can never overflow the range
  # checks below (unlike an unbounded `[0-9]*`, which lets an oversized
  # selector such as 1/999999999999999999999999 reach `[ -gt ]` and fail
  # there instead of refusing cleanly).
  if ! [[ "$shard_value" =~ ^[1-9][0-9]?/[1-9][0-9]?$ ]]; then
    usage
  fi
  index="${shard_value%%/*}"
  count="${shard_value#*/}"
  if [ "$index" -gt "$count" ] || [ "$count" -gt 16 ]; then
    usage
  fi
fi

suites=()
while IFS= read -r test_file; do
  suites+=("${test_file#"$root/"}")
done < <(find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print | LC_ALL=C sort)

total=${#suites[@]}

selected=()
if [ "$shard_given" -eq 1 ]; then
  k=0
  for path in ${suites[@]+"${suites[@]}"}; do
    if [ "$((k % count))" -eq "$((index - 1))" ]; then
      selected+=("$path")
    fi
    k=$((k + 1))
  done
else
  selected=(${suites[@]+"${suites[@]}"})
fi
m=${#selected[@]}

if [ "$total" -eq 0 ]; then
  echo "error: no scripts/test/*.test.sh files found" >&2
  exit 1
fi

if [ "$shard_given" -eq 1 ] && [ "$m" -eq 0 ]; then
  echo "error: shard $index/$count selected no test scripts" >&2
  exit 1
fi

if [ "$list_mode" -eq 1 ]; then
  for path in ${selected[@]+"${selected[@]}"}; do
    printf '%s\n' "$path"
  done
  exit 0
fi

if [ "$shard_given" -eq 1 ]; then
  printf 'shard %s/%s: %s of %s test scripts selected\n' "$index" "$count" "$m" "$total"
fi

for path in ${selected[@]+"${selected[@]}"}; do
  printf '\n==> %s\n' "$path"
  bash "$root/$path"
done

printf '\nall %s test scripts passed\n' "$m"
