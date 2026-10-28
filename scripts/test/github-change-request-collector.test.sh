#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
python=python3
if [ -x /opt/homebrew/bin/python3.12 ]; then python=/opt/homebrew/bin/python3.12; fi
case "$(uname -s):$(uname -m)" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) printf 'unsupported jq proof platform\n' >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ "$(shasum -a 256 "$jq_bin" | awk '{print $1}')" = "$digest" ] || {
  printf 'verified jq 1.6 fixture required\n' >&2; exit 1;
}
export COLLECTOR_TEST_JQ="$jq_bin"
exec "$python" -I -S -B "$root/scripts/test/fixtures/github-change-request-collector/v1/test_collector.py"
