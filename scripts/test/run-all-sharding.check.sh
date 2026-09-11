#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
runner="$root/scripts/test/run-all.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passed=0
failed=0

check() {
  # check <description> <status>  -- status 0 means the assertion held.
  local desc=$1 status=$2
  if [ "$status" -eq 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $desc" >&2
  fi
}

fail() {
  # fail <message> -- unconditional failure with a message, then record it.
  echo "FAIL: $1" >&2
  failed=$((failed + 1))
}

bounded_list() {
  # bounded_list <outfile> [args...] -- run run-all.sh under a wall-clock bound
  # and capture stdout to outfile. Returns the run's exit status via $?; a
  # timeout (perl's alarm) yields 142.
  local out=$1
  shift
  local status=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" "$@" >"$out" 2>"$tmpdir/stderr.tmp" || status=$?
  return "$status"
}

# ---------------------------------------------------------------------------
# Precondition: the runner must already implement --shard/--list. Check this
# statically, before ever invoking it, so a pre-fix run cannot fall through to
# the 80-90 minute serial suite. Grep -F keeps the usage line's <, > and
# parens literal; the --list case label is passed via -e since it begins with
# "--" and would otherwise be read as an option.
# ---------------------------------------------------------------------------
usage_line='usage: run-all.sh [--shard <index>/<count>] [--list] (1 <= index <= count <= 16)'

precondition_ok=1
if ! grep -Fq "$usage_line" "$runner"; then
  precondition_ok=0
fi
if ! grep -Fq -e '--list)' "$runner"; then
  precondition_ok=0
fi

if [ "$precondition_ok" -ne 1 ]; then
  echo "error: run-all.sh does not implement --shard/--list yet" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# The raw suite list: the oracle. Built directly, without asking the runner,
# so the proof does not merely check the runner's self-consistency.
# ---------------------------------------------------------------------------
raw_list="$tmpdir/raw.txt"
find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print \
  | LC_ALL=C sort | sed "s|^$root/||" > "$raw_list"

# 1. --list with no selector equals the raw list.
list_all="$tmpdir/list_all.txt"
status=0
bounded_list "$list_all" --list || status=$?
if [ "$status" -eq 142 ]; then
  fail "run-all.sh --list did not return within 60s (the runner started a suite)"
elif [ "$status" -ne 0 ]; then
  fail "run-all.sh --list exited $status, expected 0"
else
  if cmp -s "$raw_list" "$list_all"; then
    check "--list with no selector equals the raw list" 0
  else
    check "--list with no selector equals the raw list" 1
  fi
fi

# 2. --shard 1/1 --list equals --list with no selector.
list_1_1="$tmpdir/list_1_1.txt"
status=0
bounded_list "$list_1_1" --shard 1/1 --list || status=$?
if [ "$status" -eq 142 ]; then
  fail "run-all.sh --shard 1/1 --list did not return within 60s (the runner started a suite)"
elif [ "$status" -ne 0 ]; then
  fail "run-all.sh --shard 1/1 --list exited $status, expected 0"
else
  if cmp -s "$list_all" "$list_1_1"; then
    check "--shard 1/1 --list equals --list with no selector" 0
  else
    check "--shard 1/1 --list equals --list with no selector" 1
  fi
fi

# 3, 4. Exact membership/order per shard, plus union and disjointness, for
# every count from 1 to 16 and every index from 1 to that count (136 pairs).
for n in $(seq 1 16); do
  concat="$tmpdir/concat-$n.txt"
  : > "$concat"
  for i in $(seq 1 "$n"); do
    expected="$tmpdir/expected-$n-$i.txt"
    actual="$tmpdir/actual-$n-$i.txt"
    awk -v i="$i" -v n="$n" '((NR - 1) % n) + 1 == i' "$raw_list" > "$expected"

    status=0
    bounded_list "$actual" --shard "$i/$n" --list || status=$?
    if [ "$status" -eq 142 ]; then
      fail "run-all.sh --shard $i/$n --list did not return within 60s (the runner started a suite)"
      continue
    elif [ "$status" -ne 0 ]; then
      fail "run-all.sh --shard $i/$n --list exited $status, expected 0"
      continue
    fi

    if cmp -s "$expected" "$actual"; then
      check "shard $i/$n exact membership and order" 0
    else
      exp_line="$(head -1 "$expected" 2>/dev/null || true)"
      act_line="$(head -1 "$actual" 2>/dev/null || true)"
      fail "shard $i/$n exact membership and order: expected first line '$exp_line', got '$act_line'"
    fi

    # Every selected path appears in the raw list.
    if comm -23 <(LC_ALL=C sort "$actual") <(LC_ALL=C sort "$raw_list") | grep -q .; then
      fail "shard $i/$n: a selected path is not in the raw list"
    else
      check "shard $i/$n: every selected path is in the raw list" 0
    fi

    cat "$actual" >> "$concat"
  done

  # No duplicate line across the n shards (pairwise disjointness plus no
  # repeat inside a shard).
  if [ "$(LC_ALL=C sort "$concat" | wc -l)" -eq "$(LC_ALL=C sort -u "$concat" | wc -l)" ]; then
    check "count $n: shards have no duplicate line" 0
  else
    fail "count $n: a suite went unrun or was duplicated (shards are not disjoint)"
  fi

  # The sorted concatenation equals the raw list.
  if cmp -s <(LC_ALL=C sort "$concat") <(LC_ALL=C sort "$raw_list"); then
    check "count $n: union of shards equals the raw list" 0
  else
    fail "count $n: a suite went unrun (union does not equal the raw list)"
  fi
done

# 5. Every refusal, as the flag and as the environment variable.
bad_values=('0/4' '5/4' '9/6' 'a/b' '1/0' '1/17' '1' '/4' '4/' '')
check_refusal() {
  # check_refusal <description> <exit_status> <stdout_file> <stderr_file>
  local desc=$1 status=$2 out=$3 err=$4
  if [ "$status" -ne 2 ]; then
    fail "$desc: exit status $status, expected 2"
    return
  fi
  if [ -s "$out" ]; then
    fail "$desc: stdout was not empty"
    return
  fi
  if ! cmp -s <(printf '%s\n' "$usage_line") "$err"; then
    fail "$desc: stderr did not match the usage line exactly"
    return
  fi
  if grep -q '^==> ' "$out" 2>/dev/null; then
    fail "$desc: a suite header appeared, a suite ran"
    return
  fi
  check "$desc" 0
}

for v in "${bad_values[@]}"; do
  out="$tmpdir/refuse-out.txt"
  err="$tmpdir/refuse-err.txt"
  status=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" --shard "$v" >"$out" 2>"$err" || status=$?
  check_refusal "refusal: --shard '$v'" "$status" "$out" "$err"

  out2="$tmpdir/refuse-out2.txt"
  err2="$tmpdir/refuse-err2.txt"
  status2=0
  YSTACK_TEST_SHARD="$v" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" >"$out2" 2>"$err2" || status2=$?
  check_refusal "refusal: YSTACK_TEST_SHARD='$v'" "$status2" "$out2" "$err2"
done

# A bare --shard with nothing after it.
out="$tmpdir/refuse-bare-out.txt"
err="$tmpdir/refuse-bare-err.txt"
status=0
/usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" --shard >"$out" 2>"$err" || status=$?
check_refusal "refusal: bare --shard with no value" "$status" "$out" "$err"

# 6. The flag wins; the variable is never read (nor validated) when the flag
# is given. Two malformed values plus one well-formed value, each compared to
# the same flag-only invocation.
baseline="$tmpdir/baseline-1-6.txt"
status=0
bounded_list "$baseline" --shard 1/6 --list || status=$?
if [ "$status" -ne 0 ]; then
  fail "baseline --shard 1/6 --list exited $status, expected 0"
fi

for v in '2/6' 'a/b' '9/6'; do
  out="$tmpdir/precedence-out.txt"
  status=0
  YSTACK_TEST_SHARD="$v" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" --shard 1/6 --list >"$out" 2>"$tmpdir/precedence-err.txt" || status=$?
  if [ "$status" -eq 142 ]; then
    fail "YSTACK_TEST_SHARD=$v --shard 1/6 --list did not return within 60s"
    continue
  elif [ "$status" -ne 0 ]; then
    fail "YSTACK_TEST_SHARD=$v --shard 1/6 --list exited $status, expected 0"
    continue
  fi
  if cmp -s "$baseline" "$out"; then
    check "flag wins over YSTACK_TEST_SHARD=$v" 0
  else
    fail "flag wins over YSTACK_TEST_SHARD=$v: output differed"
  fi
done

# 7. YSTACK_TEST_SHARD alone selects the same set as the equivalent flag.
via_env="$tmpdir/via-env.txt"
via_flag="$tmpdir/via-flag.txt"
status=0
YSTACK_TEST_SHARD='3/6' /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 bash "$runner" --list >"$via_env" 2>"$tmpdir/via-env-err.txt" || status=$?
if [ "$status" -ne 0 ]; then
  fail "YSTACK_TEST_SHARD=3/6 --list exited $status, expected 0"
else
  status2=0
  bounded_list "$via_flag" --shard 3/6 --list || status2=$?
  if [ "$status2" -ne 0 ]; then
    fail "--shard 3/6 --list exited $status2, expected 0"
  elif cmp -s "$via_env" "$via_flag"; then
    check "YSTACK_TEST_SHARD=3/6 alone equals --shard 3/6" 0
  else
    fail "YSTACK_TEST_SHARD=3/6 alone did not equal --shard 3/6"
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
  else
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      fail "no --shard run line in ci.yml: the sharded test run line was removed"
    else
      echo "workflow is still serial: no --shard run line in ci.yml"
      check "workflow is still serial (local, GITHUB_ACTIONS unset)" 0
    fi
  fi
else
  fail "workflow file not found: $workflow"
fi

echo ""
echo "assertions passed: $passed"
echo "assertions failed: $failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "sharding proof: all checks passed"
