#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
runner="$root/scripts/test/run-all.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

check() { # check <desc> <status> -- status 0 means the assertion held.
  if [ "$2" -eq 0 ]; then passed=$((passed + 1)); else fail "$1"; fi
}

fail() { # fail <message>
  echo "FAIL: $1" >&2
  failed=$((failed + 1))
}

# run <outfile> <errfile> [args...] -- run-all.sh under a 60s wall-clock
# bound (perl alarm; macOS has no timeout/gtimeout). Sets RUN_STATUS; 142
# means the bound fired, i.e. the runner started a suite instead of listing.
run() {
  local out=$1 err=$2
  shift 2
  RUN_STATUS=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" "$@" >"$out" 2>"$err" || RUN_STATUS=$?
}

# bounded_list <outfile> [args...] -- run(), asserting the bound wasn't hit.
bounded_list() {
  local out=$1 desc="run-all.sh $*"
  shift
  run "$out" "$tmpdir/err.tmp" "$@"
  if [ "$RUN_STATUS" -eq 142 ]; then
    fail "$desc did not return within 60s (the runner started a suite)"
    return 1
  elif [ "$RUN_STATUS" -ne 0 ]; then
    fail "$desc exited $RUN_STATUS, expected 0"
    return 1
  fi
}

# ---- Precondition: refuse before ever invoking the runner (Step 0). Grep -F
# keeps the usage line's <, > and parens literal; -e '--list)' is needed
# because a pattern starting with "--" would otherwise be read as an option.
usage_line='usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)'
if ! grep -Fq "$usage_line" "$runner" || ! grep -Fq -e '--list)' "$runner"; then
  echo "error: run-all.sh does not implement --shard/--list yet" >&2
  exit 2
fi

# ---- The raw suite list: the independent oracle everything below compares
# against, built without asking the runner.
raw_list="$tmpdir/raw.txt"
find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print \
  | LC_ALL=C sort | sed "s|^$root/||" > "$raw_list"

# 1. --list with no selector equals the raw list.
list_all="$tmpdir/list_all.txt"
if bounded_list "$list_all" --list; then
  check "--list with no selector equals the raw list" "$(cmp -s "$raw_list" "$list_all"; echo $?)"
fi

# 2. --shard 1/1 --list equals --list with no selector.
list_1_1="$tmpdir/list_1_1.txt"
if bounded_list "$list_1_1" --shard 1/1 --list; then
  check "--shard 1/1 --list equals --list with no selector" "$(cmp -s "$list_all" "$list_1_1"; echo $?)"
fi

# 3, 4. Exact membership/order per shard (the assertion a shifted-or-chunked
# assignment would fail), plus union and disjointness — over all 136
# index/count pairs for count 1..16.
for n in $(seq 1 16); do
  concat="$tmpdir/concat-$n.txt"
  : > "$concat"
  for i in $(seq 1 "$n"); do
    expected="$tmpdir/expected.txt"
    actual="$tmpdir/actual-$n-$i.txt"
    awk -v i="$i" -v n="$n" '((NR - 1) % n) + 1 == i' "$raw_list" > "$expected"
    if bounded_list "$actual" --shard "$i/$n" --list; then
      if cmp -s "$expected" "$actual"; then
        check "shard $i/$n exact membership and order" 0
      else
        fail "shard $i/$n exact membership and order: expected first line '$(head -1 "$expected")', got '$(head -1 "$actual")'"
      fi
      cat "$actual" >> "$concat"
    fi
  done
  # No duplicate line across the n shards (pairwise disjoint, no repeat), and
  # the sorted concatenation equals the raw list (nothing went unrun).
  if [ "$(LC_ALL=C sort "$concat" | wc -l)" -eq "$(LC_ALL=C sort -u "$concat" | wc -l)" ]; then
    check "count $n: shards have no duplicate line" 0
  else
    fail "count $n: a suite went unrun or was duplicated (shards are not disjoint)"
  fi
  if cmp -s <(LC_ALL=C sort "$concat") <(LC_ALL=C sort "$raw_list"); then
    check "count $n: union of shards equals the raw list" 0
  else
    fail "count $n: a suite went unrun (union does not equal the raw list)"
  fi
done

# 5. Every refusal (R5), as the flag and as YSTACK_TEST_SHARD, plus a bare
# --shard with no value.
check_refusal() { # check_refusal <desc> <outfile> <errfile>
  local desc=$1 out=$2 err=$3
  if [ "$RUN_STATUS" -ne 2 ]; then
    fail "$desc: exit status $RUN_STATUS, expected 2"
  elif [ -s "$out" ]; then
    fail "$desc: stdout was not empty"
  elif ! cmp -s <(printf '%s\n' "$usage_line") "$err"; then
    fail "$desc: stderr did not match the usage line exactly"
  else
    check "$desc" 0
  fi
}

bad_values=('0/4' '5/4' '9/6' 'a/b' '1/0' '1/17' '1' '/4' '4/' '')
for v in "${bad_values[@]}"; do
  out="$tmpdir/ro.txt"; err="$tmpdir/re.txt"
  run "$out" "$err" --shard "$v"
  check_refusal "refusal: --shard '$v'" "$out" "$err"

  out2="$tmpdir/ro2.txt"; err2="$tmpdir/re2.txt"
  RUN_STATUS=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 env YSTACK_TEST_SHARD="$v" bash "$runner" >"$out2" 2>"$err2" || RUN_STATUS=$?
  check_refusal "refusal: YSTACK_TEST_SHARD='$v'" "$out2" "$err2"
done

out="$tmpdir/ro.txt"; err="$tmpdir/re.txt"
run "$out" "$err" --shard
check_refusal "refusal: bare --shard with no value" "$out" "$err"

# 6. The flag wins; the variable is neither read nor validated when the flag
# is given. Two malformed values plus one well-formed one, each compared
# against the same flag-only invocation.
baseline="$tmpdir/baseline.txt"
bounded_list "$baseline" --shard 1/6 --list || true
for v in '2/6' 'a/b' '9/6'; do
  out="$tmpdir/prec.txt"
  RUN_STATUS=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 env YSTACK_TEST_SHARD="$v" bash "$runner" --shard 1/6 --list >"$out" 2>"$tmpdir/prec-err.txt" || RUN_STATUS=$?
  if [ "$RUN_STATUS" -eq 142 ]; then
    fail "YSTACK_TEST_SHARD=$v --shard 1/6 --list did not return within 60s"
  elif [ "$RUN_STATUS" -ne 0 ]; then
    fail "YSTACK_TEST_SHARD=$v --shard 1/6 --list exited $RUN_STATUS, expected 0"
  else
    check "flag wins over YSTACK_TEST_SHARD=$v" "$(cmp -s "$baseline" "$out"; echo $?)"
  fi
done

# 7. YSTACK_TEST_SHARD alone selects the same set as the equivalent flag.
via_env="$tmpdir/via-env.txt"
RUN_STATUS=0
/usr/bin/perl -e 'alarm shift; exec @ARGV' 60 env YSTACK_TEST_SHARD='3/6' bash "$runner" --list >"$via_env" 2>"$tmpdir/via-env-err.txt" || RUN_STATUS=$?
if [ "$RUN_STATUS" -ne 0 ]; then
  fail "YSTACK_TEST_SHARD=3/6 --list exited $RUN_STATUS, expected 0"
else
  via_flag="$tmpdir/via-flag.txt"
  if bounded_list "$via_flag" --shard 3/6 --list; then
    check "YSTACK_TEST_SHARD=3/6 alone equals --shard 3/6" "$(cmp -s "$via_env" "$via_flag"; echo $?)"
  fi
fi

# 8. The workflow's shard count equals its matrix (R10). Reading a
# constitution path is allowed; writing one is not.
workflow="$root/.github/workflows/ci.yml"
if [ -f "$workflow" ]; then
  run_line="$(grep -E 'bash scripts/test/run-all\.sh --shard \$\{\{ *matrix\.shard *\}\}/[0-9]+' "$workflow" || true)"
  if [ -n "$run_line" ]; then
    shard_n="$(printf '%s\n' "$run_line" | sed -E 's#.*--shard \$\{\{ *matrix\.shard *\}\}/([0-9]+).*#\1#')"
    matrix_line="$(grep -E '^[[:space:]]*shard:[[:space:]]*\[' "$workflow" || true)"
    matrix_list="$(printf '%s\n' "$matrix_line" | sed -E 's/^[[:space:]]*shard:[[:space:]]*\[([^]]*)\].*/\1/' | tr -d ' ')"
    expected_list="$(seq 1 "$shard_n" | paste -sd, -)"
    if [ -n "$matrix_line" ] && [ "$matrix_list" = "$expected_list" ]; then
      check "workflow shard count equals its matrix (N=$shard_n)" 0
    else
      fail "workflow shard count mismatch: run line says N=$shard_n, matrix list is '$matrix_list'"
    fi
  elif [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    fail "no --shard run line in ci.yml: the sharded test run line was removed"
  else
    echo "workflow is still serial: no --shard run line in ci.yml"
    check "workflow is still serial (local, GITHUB_ACTIONS unset)" 0
  fi
else
  fail "workflow file not found: $workflow"
fi

echo ""
echo "assertions passed: $passed"
echo "assertions failed: $failed"
[ "$failed" -eq 0 ] || exit 1
echo "sharding proof: all checks passed"
