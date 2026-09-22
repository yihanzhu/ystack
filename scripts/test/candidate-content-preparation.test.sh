#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
component="$root/preparation/v1/prepare-candidate.py"
helper="$root/scripts/test/candidate-content-preparation-fixtures.py"
builder="$root/scripts/test/local-git-materializer-fixtures.sh"
materializer="$root/adapters/local-git-materializer/v1/materialize.sh"
closure_source="$root/adapters/local-git-materializer/v1/object-closure.c"
python=/opt/homebrew/bin/python3
[ -x "$python" ] || python=/usr/bin/python3
test_tmp_base=${TMPDIR:-/tmp}
tmp=$(/usr/bin/mktemp -d "${test_tmp_base%/}/ystack-candidate-preparation.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() {
  local status=$?
  /bin/chmod -R u+rwx "$tmp" 2>/dev/null || :
  /bin/rm -rf -- "$tmp"
  exit "$status"
}
trap cleanup EXIT

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$jq_sha" ] || {
  printf '%s\n' 'FAIL: pinned jq 1.6 is required' >&2
  exit 1
}
jq_bin=$(CDPATH='' cd -P -- "$(dirname "$jq_bin")" && pwd -P)/$(basename "$jq_bin")
[ "$($jq_bin --version)" = jq-1.6 ] || exit 1
[ "$($python --version 2>&1 | /usr/bin/awk '{print $2}' | /usr/bin/cut -d. -f1)" -ge 3 ] || exit 1

/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 "$closure_source" -o "$tmp/object-closure"
/bin/chmod 0500 "$tmp/object-closure"
/bin/mkdir -m 700 "$tmp/home" "$tmp/cases"

passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects "$@"
}

make_source() {
  local destination=$1 algorithm=$2 source_blob binary_blob exec_blob repeat_blob nested_blob
  local nested_tree root_tree commit empty_template="$tmp/empty-template"
  [ -d "$empty_template" ] || /bin/mkdir -m 500 "$empty_template"
  /bin/mkdir -m 700 "$destination"
  git_clean init -q --template="$empty_template" --bare --object-format="$algorithm" "$destination"
  source_blob=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  binary_blob=$(printf '\000binary\r\nbytes' | git_clean --git-dir="$destination" hash-object -w --stdin)
  exec_blob=$(printf '#!/bin/sh\nprintf trap-ran\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  repeat_blob=$(printf 'repeat-without-newline' | git_clean --git-dir="$destination" hash-object -w --stdin)
  nested_blob=$(printf 'utf8-\303\251\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  nested_tree=$(printf '100644 blob %s\tutf8-\303\251.txt\n' "$nested_blob" |
    git_clean --git-dir="$destination" mktree)
  root_tree=$(
    printf '100644 blob %s\tbinary.bin\n' "$binary_blob"
    printf '100755 blob %s\texecutable.sh\n' "$exec_blob"
    printf '040000 tree %s\tnested\n' "$nested_tree"
    printf '100644 blob %s\trepeat-a.txt\n' "$repeat_blob"
    printf '100644 blob %s\trepeat-b.txt\n' "$repeat_blob"
    printf '100644 blob %s\tsource.txt\n' "$source_blob"
  )
  root_tree=$(printf '%s\n' "$root_tree" | git_clean --git-dir="$destination" mktree)
  commit=$(printf 'source fixture\n' |
    /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
      GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
      GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
      GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
      /usr/bin/git --no-replace-objects --git-dir="$destination" commit-tree "$root_tree")
  git_clean --git-dir="$destination" update-ref refs/heads/main "$commit"
  printf '%s %s\n' "$commit" "$root_tree"
}

make_description() {
  local destination=$1 changed=$2 source_text
  source_text='alpha\nbeta\n'
  [ "$changed" = true ] && source_text='alpha\nbeta\ngamma\n'
  "$python" - "$destination" "$source_text" <<'PY'
import json,sys
path,text=sys.argv[1:]
entries=[
 {"path":"binary.bin","git_mode":"100644","content_hex":"0062696e6172790d0a6279746573"},
 {"path":"executable.sh","git_mode":"100755","content_utf8":"#!/bin/sh\nprintf trap-ran\n"},
 {"path":"nested/utf8-é.txt","git_mode":"100644","content_utf8":"utf8-é\n"},
 {"path":"repeat-a.txt","git_mode":"100644","content_utf8":"repeat-without-newline"},
 {"path":"repeat-b.txt","git_mode":"100644","content_utf8":"repeat-without-newline"},
 {"path":"source.txt","git_mode":"100644","content_utf8":text.replace("\\n","\n")},
]
open(path,"w",encoding="utf-8").write(json.dumps({"entries":entries},ensure_ascii=False,separators=(",",":"))+"\n")
PY
}

make_nochange_input() {
  local source=$1 destination=$2 intermediate="$tmp/nochange-intermediate.json" empty_sha
  empty_sha=$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  "$jq_bin" -S -c --arg sha "$empty_sha" '
    (.payloads[] | select(.input_id=="input.producer-patch")) |= (.data="") |
    (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch")) |=
      (.content.data="" | .sha256=$sha) |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.producer-patch") |
      .value.value.value.sha256)=$sha
  ' "$source" > "$intermediate"
  "$jq_bin" -S -c '.stage_request.content' "$intermediate" > "$tmp/nochange-request.json"
  "$jq_bin" -S -c --arg sha "$(sha_file "$tmp/nochange-request.json")" \
    '.stage_request.sha256=$sha' "$intermediate" > "$destination"
}

invoke_prepare() {
  local operation=$1 input=$2 response=$3 candidate=$4 output=$5 scratch=$6
  "$python" -I "$component" "$operation" \
    --input "$input" --input-sha256 "$(sha_file "$input")" \
    --response "$response" --response-sha256 "$(sha_file "$response")" \
    --candidate-repository "$candidate" --output "$output" --scratch "$scratch" --jq "$jq_bin"
}

build_case() {
  local name=$1 algorithm=$2 changed=$3 source commit tree input case_root
  case_root="$tmp/cases/$name"
  /bin/mkdir -m 700 "$case_root" "$case_root/materialized" "$case_root/materializer-scratch" \
    "$case_root/prep-scratch" "$case_root/output-parent"
  source="$case_root/source.git"
  read -r commit tree < <(make_source "$source" "$algorithm")
  "$builder" build "$case_root/fixture" "$jq_bin" "$algorithm" "$commit" "$tree"
  input="$case_root/fixture/input.json"
  if [ "$changed" = false ]; then
    make_nochange_input "$input" "$case_root/input-nochange.json"
    input="$case_root/input-nochange.json"
  fi
  "$materializer" materialize "$input" fixture.target "$source" "$case_root/materialized" \
    "$case_root/materializer-scratch" "$tmp/object-closure" "$jq_bin" > "$case_root/response.json"
  [ ! -e "$case_root/materialized/repository.git/index" ] || fail "$name producer index escaped scratch"
  invoke_prepare prepare "$input" "$case_root/response.json" "$case_root/materialized/repository.git" \
    "$case_root/output-parent/bundle" "$case_root/prep-scratch" > "$case_root/prepare.out"
  invoke_prepare inspect "$input" "$case_root/response.json" "$case_root/materialized/repository.git" \
    "$case_root/output-parent/bundle" "$case_root/prep-scratch" > "$case_root/inspect.out"
  /usr/bin/cmp -s "$case_root/prepare.out" "$case_root/inspect.out" || fail "$name recovery envelope"
  make_description "$case_root/description.json" "$changed"
  "$python" -I "$helper" oracle check --description "$case_root/description.json" \
    --root "$case_root/output-parent/bundle/candidate" --algorithm "$algorithm" \
    --manifest "$case_root/output-parent/bundle/manifest.json" --root-mode 0500
  /usr/bin/cmp -s "$source/objects/pack"/*.rev "$case_root/materialized/repository.git/objects/pack"/*.rev 2>/dev/null || :
  [ -n "$(find "$case_root/materialized/repository.git/objects/pack" -name '*.rev' -print -quit)" ] ||
    fail "$name real reverse index absent"
  [ -z "$(find "$case_root/output-parent/bundle" -name '*.rev' -print -quit)" ] || fail "$name sidecar published"
  pass "$name real materializer, exact export, and inspect"
}

build_case sha1-changed sha1 true
build_case sha1-nochange sha1 false
if git_clean init -q --bare --object-format=sha256 "$tmp/sha256-probe.git" 2>/dev/null; then
  build_case sha256-changed sha256 true
  build_case sha256-nochange sha256 false
else
  fail 'supported Git lacks SHA-256 object format'
fi

base="$tmp/cases/sha1-changed"
input="$base/fixture/input.json"
response="$base/response.json"
candidate="$base/materialized/repository.git"

expect_error() {
  local name=$1 expected=$2 exit_code=$3; shift 3
  local actual case_root
  case_root="$tmp/error-$name"
  /bin/mkdir -p "$case_root" "$case_root/scratch" "$case_root/output-parent"
  /bin/chmod 0700 "$case_root" "$case_root/scratch" "$case_root/output-parent"
  if "$@" > "$case_root/out" 2> "$case_root/err"; then
    fail "$name accepted"
  else
    actual=$?
  fi
  [ "$actual" -eq "$exit_code" ] && [ ! -s "$case_root/out" ] && \
    [ "$(cat "$case_root/err")" = "$expected" ] || fail "$name result"
  pass "$name refused as $expected"
}

expect_error wrong-input-hash E_IDENTITY 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(printf '%064d' 0)" --response "$response" \
  --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
  --output "$tmp/error-wrong-input-hash/output-parent/bundle" \
  --scratch "$tmp/error-wrong-input-hash/scratch" --jq "$jq_bin"

duplicate_root="$tmp/error-duplicate-option"
/bin/mkdir -m 700 "$duplicate_root" "$duplicate_root/scratch" "$duplicate_root/output-parent"
expect_error duplicate-option E_USAGE 2 "$python" -I "$component" prepare \
  --input="$input" --input="$input" --input-sha256 "$(sha_file "$input")" \
  --response "$response" --response-sha256 "$(sha_file "$response")" \
  --candidate-repository "$candidate" --output "$duplicate_root/output-parent/bundle" \
  --scratch "$duplicate_root/scratch" --jq "$jq_bin"
[ ! -e "$duplicate_root/output-parent/bundle" ] && \
  [ -z "$(find "$duplicate_root/scratch" -mindepth 1 -print -quit)" ] || fail duplicate-created-output

mkdir -m 700 "$tmp/mutated"
"$jq_bin" -S -c '
  (.payloads[] | select(.input_id=="input.producer-patch").data)+="x" |
  (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch").content.data)+="x"
' "$input" > "$tmp/mutated/raw-payload.json"
expect_error raw-payload-digest E_INPUT 1 invoke_prepare prepare "$tmp/mutated/raw-payload.json" \
  "$response" "$candidate" "$tmp/error-raw-payload-digest/output-parent/bundle" \
  "$tmp/error-raw-payload-digest/scratch"

"$python" -I "$helper" json-case --input "$input" --output "$tmp/mutated/surrogate.json" --case lone-surrogate
expect_error escaped-surrogate E_INPUT 1 invoke_prepare prepare "$tmp/mutated/surrogate.json" \
  "$response" "$candidate" "$tmp/error-escaped-surrogate/output-parent/bundle" \
  "$tmp/error-escaped-surrogate/scratch"
"$python" -I "$helper" json-case --input "$input" --output "$tmp/mutated/deep.json" --case depth-33
expect_error json-depth E_INPUT 1 invoke_prepare prepare "$tmp/mutated/deep.json" \
  "$response" "$candidate" "$tmp/error-json-depth/output-parent/bundle" \
  "$tmp/error-json-depth/scratch"

storage_copy="$tmp/storage-extra.git"
/bin/cp -R "$candidate" "$storage_copy"
/usr/bin/touch "$storage_copy/extra"
expect_error storage-extra E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_copy" \
  "$tmp/error-storage-extra/output-parent/bundle" "$tmp/error-storage-extra/scratch"

reverse_copy="$tmp/storage-reverse.git"
/bin/cp -R "$candidate" "$reverse_copy"
reverse=$(find "$reverse_copy/objects/pack" -name '*.rev' -print -quit)
[ -n "$reverse" ] || fail reverse-index-copy-absent
/bin/chmod u+w "$reverse" || fail reverse-index-chmod
printf x | /bin/dd of="$reverse" bs=1 seek=0 conv=notrunc 2>/dev/null || fail reverse-index-write
expect_error reverse-index-corrupt E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$reverse_copy" \
  "$tmp/error-reverse-index-corrupt/output-parent/bundle" "$tmp/error-reverse-index-corrupt/scratch"

collision="$tmp/cases/sha1-changed/output-parent/bundle"
expect_error prepare-collision E_EXISTS 2 invoke_prepare prepare "$input" "$response" "$candidate" \
  "$collision" "$tmp/error-prepare-collision/scratch"

restore="$tmp/restored"
/bin/mkdir -m 700 "$restore" "$restore/scratch"
/bin/cp -R "$collision" "$restore/bundle"
/bin/chmod 0700 "$restore/bundle"
invoke_prepare inspect "$input" "$response" "$candidate" "$restore/bundle" "$restore/scratch" \
  > "$restore/inspect.out"
/usr/bin/cmp -s "$base/prepare.out" "$restore/inspect.out" || fail restoration-envelope
pass 'complete bundle restores under new private paths'

/bin/chmod 0600 "$restore/bundle/candidate/source.txt"
expect_error same-owner-mode-change E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$restore/bundle" "$tmp/error-same-owner-mode-change/scratch"

"$python" -I "$helper" limits > "$tmp/limits.json"
"$python" - "$tmp/limits.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))["limits"]
assert rows and all(row["inclusive"]+1==row["overflow"] for row in rows)
assert {"input_bytes","storage_bytes","blob_bytes","bundle_bytes"} <= {row["name"] for row in rows}
PY
pass 'inclusive limit ledger covers every named bound'

argv_json="$tmp/inject-argv.json"
"$python" - "$argv_json" "$input" "$response" "$candidate" "$tmp" "$jq_bin" <<'PY'
import hashlib,json,sys
out,inp,response,candidate,tmp,jq=sys.argv[1:]
sha=lambda p:hashlib.sha256(open(p,"rb").read()).hexdigest()
argv=["prepare","--input",inp,"--input-sha256",sha(inp),"--response",response,
      "--response-sha256",sha(response),"--candidate-repository",candidate,
      "--output",tmp+"/injected-output/bundle","--scratch",tmp+"/injected-scratch","--jq",jq]
open(out,"w").write(json.dumps(argv))
PY
/bin/mkdir -m 700 "$tmp/injected-output" "$tmp/injected-scratch"
if "$python" -I "$helper" inject --component "$component" --target write_exclusive \
    --mode before-error --argv-json "$argv_json" > "$tmp/injected.out" 2> "$tmp/injected.err"; then
  fail injected-write-accepted
fi
[ ! -s "$tmp/injected.out" ] && [ "$(cat "$tmp/injected.err")" = E_IO ] || fail injected-write-result
pass 'narrow production write fault preserves incomplete state'

printf '1..%s\n' "$passed"
