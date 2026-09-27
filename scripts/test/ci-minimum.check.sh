#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
workflow="$root/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gate="$tmp/gate.sh"

awk '
  /# ci-minimum-gate:start/ { inside=1; next }
  /# ci-minimum-gate:end/ { inside=0; found=1; next }
  inside { sub(/^          /, ""); print }
  END { if (!found) exit 1 }
' "$workflow" >"$gate"

if [ "$(grep -c '# ci-minimum-gate:start' "$workflow")" -ne 1 ] \
  || [ "$(grep -c '# ci-minimum-gate:end' "$workflow")" -ne 1 ]; then
  echo "gate markers must appear exactly once" >&2
  exit 1
fi

grep -Fq "workflow_dispatch:" "$workflow"
grep -Fq "if: github.event_name == 'workflow_dispatch'" "$workflow"
grep -Fq "needs: [checks, test]" "$workflow"
grep -Fq "if: always()" "$workflow"

expect() {
  expected=$1
  event_name=$2
  checks_result=$3
  test_result=$4
  if EVENT_NAME="$event_name" CHECKS_RESULT="$checks_result" TEST_RESULT="$test_result" \
      sh "$gate" >"$tmp/out" 2>"$tmp/err"; then
    actual=success
  else
    actual=failure
  fi
  if [ "$actual" != "$expected" ]; then
    echo "expected $expected for $event_name/$checks_result/$test_result, got $actual" >&2
    exit 1
  fi
}

expect success pull_request success skipped
expect success push success skipped
expect success workflow_dispatch success success

for event_name in pull_request push workflow_dispatch unknown; do
  for checks_result in failure cancelled skipped; do
    for test_result in success failure cancelled skipped; do
      expect failure "$event_name" "$checks_result" "$test_result"
    done
  done
done

for test_result in success failure cancelled; do
  expect failure pull_request success "$test_result"
  expect failure push success "$test_result"
done
for test_result in failure cancelled skipped; do
  expect failure workflow_dispatch success "$test_result"
done
for test_result in success failure cancelled skipped; do
  expect failure unknown success "$test_result"
done

echo "minimal CI gate proof: all checks passed"
