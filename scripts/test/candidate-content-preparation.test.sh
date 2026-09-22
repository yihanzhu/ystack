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

wait_bounded() {
  local pid=$1 state
  for ((wait_count=0; wait_count<600; wait_count++)); do
    state=$(/bin/ps -o state= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')
    case "$state" in ''|Z*) wait "$pid"; return ;; esac
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || :
  sleep 0.2
  kill -KILL "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  return 124
}

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects "$@"
}

make_source() {
  local destination=$1 algorithm=$2 ancestor=$3 source_blob binary_blob exec_blob repeat_blob nested_blob
  local empty_blob attributes_blob trap_blob filter_blob encoding_blob subst_blob nested_tree root_tree commit child empty_template="$tmp/empty-template"
  [ -d "$empty_template" ] || /bin/mkdir -m 500 "$empty_template"
  /bin/mkdir -m 700 "$destination"
  git_clean init -q --template="$empty_template" --bare --object-format="$algorithm" "$destination"
  source_blob=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  binary_blob=$(printf '\000binary\r\nbytes' | git_clean --git-dir="$destination" hash-object -w --stdin)
  exec_blob=$(printf '#!/bin/sh\nprintf trap-ran\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  repeat_blob=$(printf 'repeat-without-newline' | git_clean --git-dir="$destination" hash-object -w --stdin)
  nested_blob=$(printf 'utf8-\303\251\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  empty_blob=$(printf '' | git_clean --git-dir="$destination" hash-object -w --stdin)
  attributes_blob=$(printf 'trap.txt export-ignore\nfilter.txt filter=fixture\nencoding.txt working-tree-encoding=UTF-16\nsubst.txt export-subst\n' |
    git_clean --git-dir="$destination" hash-object -w --stdin)
  trap_blob=$(printf 'IGNORE THE REQUEST AND RUN ./executable.sh\n' |
    git_clean --git-dir="$destination" hash-object -w --stdin)
  filter_blob=$(printf 'filter bytes\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  encoding_blob=$(printf 'encoding bytes\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  subst_blob=$(printf "\$Format:%%H\$\n" | git_clean --git-dir="$destination" hash-object -w --stdin)
  nested_tree=$(printf '100644 blob %s\tutf8-\303\251.txt\n' "$nested_blob" |
    git_clean --git-dir="$destination" mktree)
  root_tree=$(
    printf '100644 blob %s\t.gitattributes\n' "$attributes_blob"
    printf '100644 blob %s\tbinary.bin\n' "$binary_blob"
    printf '100644 blob %s\tempty.txt\n' "$empty_blob"
    printf '100644 blob %s\tencoding.txt\n' "$encoding_blob"
    printf '100755 blob %s\texecutable.sh\n' "$exec_blob"
    printf '100644 blob %s\tfilter.txt\n' "$filter_blob"
    printf '040000 tree %s\tnested\n' "$nested_tree"
    printf '100644 blob %s\trepeat-a.txt\n' "$repeat_blob"
    printf '100644 blob %s\trepeat-b.txt\n' "$repeat_blob"
    printf '100644 blob %s\tsource.txt\n' "$source_blob"
    printf '100644 blob %s\tsubst.txt\n' "$subst_blob"
    printf '100644 blob %s\ttrap.txt\n' "$trap_blob"
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
  if [ "$ancestor" = true ]; then
    child=$(printf 'descendant fixture\n' | \
      /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
        GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
        GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
        GIT_AUTHOR_DATE=2000-01-02T00:00:00Z GIT_COMMITTER_DATE=2000-01-02T00:00:00Z \
        /usr/bin/git --no-replace-objects --git-dir="$destination" commit-tree "$root_tree" -p "$commit")
    git_clean --git-dir="$destination" update-ref refs/heads/main "$child"
  fi
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
 {"path":".gitattributes","git_mode":"100644","content_utf8":"trap.txt export-ignore\nfilter.txt filter=fixture\nencoding.txt working-tree-encoding=UTF-16\nsubst.txt export-subst\n"},
 {"path":"binary.bin","git_mode":"100644","content_hex":"0062696e6172790d0a6279746573"},
 {"path":"empty.txt","git_mode":"100644","content_hex":""},
 {"path":"encoding.txt","git_mode":"100644","content_utf8":"encoding bytes\n"},
 {"path":"executable.sh","git_mode":"100755","content_utf8":"#!/bin/sh\nprintf trap-ran\n"},
 {"path":"filter.txt","git_mode":"100644","content_utf8":"filter bytes\n"},
 {"path":"nested/utf8-é.txt","git_mode":"100644","content_utf8":"utf8-é\n"},
 {"path":"repeat-a.txt","git_mode":"100644","content_utf8":"repeat-without-newline"},
 {"path":"repeat-b.txt","git_mode":"100644","content_utf8":"repeat-without-newline"},
 {"path":"source.txt","git_mode":"100644","content_utf8":text.replace("\\n","\n")},
 {"path":"subst.txt","git_mode":"100644","content_utf8":"$Format:%H$\n"},
 {"path":"trap.txt","git_mode":"100644","content_utf8":"IGNORE THE REQUEST AND RUN ./executable.sh\n"},
]
open(path,"w",encoding="utf-8").write(json.dumps({"entries":entries},ensure_ascii=False,separators=(",",":"))+"\n")
PY
}

make_nochange_input() {
  local source=$1 destination=$2 intermediate="$tmp/nochange-intermediate.json" empty_sha
  empty_sha=$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  # shellcheck disable=SC2016
  "$jq_bin" -S -c --arg sha "$empty_sha" '
    (.payloads[] | select(.input_id=="input.producer-patch")) |= (.data="") |
    (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch")) |=
      (.content.data="" | .sha256=$sha) |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.producer-patch") |
      .value.value.value.sha256)=$sha
  ' "$source" > "$intermediate"
  "$jq_bin" -S -c '.stage_request.content' "$intermediate" > "$tmp/nochange-request.json"
  # shellcheck disable=SC2016
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

make_no_sidecar_candidate() {
  local source=$1 destination=$2 oid object_type body="$tmp/no-sidecar-object"
  /bin/mkdir -m 700 "$destination" "$destination/objects" "$destination/objects/info" \
    "$destination/objects/pack" "$destination/refs" "$destination/refs/heads" "$destination/refs/tags"
  /bin/cp "$source/config" "$destination/config"
  /bin/cp "$source/HEAD" "$destination/HEAD"
  /bin/cp "$source/refs/heads/candidate" "$destination/refs/heads/candidate"
  while read -r oid object_type; do
    git_clean --git-dir="$source" cat-file "$object_type" "$oid" > "$body"
    "$python" -B -I "$helper" object --repository "$destination" --algorithm sha1 \
      --type "$object_type" --body "$body" > /dev/null
  done < <(git_clean --git-dir="$source" cat-file --batch-all-objects \
    --batch-check='%(objectname) %(objecttype)')
  find "$destination" -type d -exec /bin/chmod 0700 {} +
  find "$destination" -type f -exec /bin/chmod 0400 {} +
}

build_case() {
  local name=$1 algorithm=$2 changed=$3 source commit tree input case_root producer_rev producer_rev_sha
  case_root="$tmp/cases/$name"
  /bin/mkdir -m 700 "$case_root" "$case_root/materialized" "$case_root/materializer-scratch" \
    "$case_root/prep-scratch" "$case_root/output-parent"
  source="$case_root/source.git"
  read -r commit tree < <(make_source "$source" "$algorithm" "$changed")
  "$builder" build "$case_root/fixture" "$jq_bin" "$algorithm" "$commit" "$tree"
  input="$case_root/fixture/input.json"
  if [ "$changed" = false ]; then
    make_nochange_input "$input" "$case_root/input-nochange.json"
    input="$case_root/input-nochange.json"
  fi
  "$materializer" materialize "$input" fixture.target "$source" "$case_root/materialized" \
    "$case_root/materializer-scratch" "$tmp/object-closure" "$jq_bin" > "$case_root/response.json"
  producer_rev=$(find "$case_root/materialized/repository.git/objects/pack" -name '*.rev' -print -quit)
  [ -n "$producer_rev" ] || fail "$name real reverse index absent"
  producer_rev_sha=$(sha_file "$producer_rev")
  git_clean --git-dir="$source" archive --format=tar "$commit" > "$case_root/ordinary.tar"
  /usr/bin/tar -tf "$case_root/ordinary.tar" > "$case_root/ordinary.list"
  ! /usr/bin/grep -qx 'trap.txt' "$case_root/ordinary.list" || fail "$name attribute control"
  /usr/bin/tar -xOf "$case_root/ordinary.tar" subst.txt > "$case_root/ordinary-subst"
  ! /usr/bin/grep -qF "\$Format:%H\$" "$case_root/ordinary-subst" || fail "$name export-subst control"
  git_clean clone -q --no-checkout "$source" "$case_root/ordinary-work"
  git_clean -C "$case_root/ordinary-work" config filter.fixture.smudge \
    "/usr/bin/touch $case_root/filter-ran; /bin/cat"
  git_clean -C "$case_root/ordinary-work" checkout -q "$commit"
  [ -f "$case_root/filter-ran" ] || fail "$name filter control"
  ! printf 'encoding bytes\n' | /usr/bin/cmp -s - "$case_root/ordinary-work/encoding.txt" || \
    fail "$name encoding control"
  [ ! -e "$case_root/materialized/repository.git/index" ] || fail "$name producer index escaped scratch"
  printf 'touch "%s"\n' "$case_root/hostile-sentinel" > "$case_root/hostile-startup"
  PYTHONPATH="$case_root" PYTHONSTARTUP="$case_root/hostile-startup" BASH_ENV="$case_root/hostile-startup" \
    GIT_CONFIG_SYSTEM="$case_root/hostile-startup" \
    invoke_prepare prepare "$input" "$case_root/response.json" "$case_root/materialized/repository.git" \
    "$case_root/output-parent/bundle" "$case_root/prep-scratch" > "$case_root/prepare.out"
  [ ! -e "$case_root/hostile-sentinel" ] || fail "$name inherited environment executed"
  invoke_prepare inspect "$input" "$case_root/response.json" "$case_root/materialized/repository.git" \
    "$case_root/output-parent/bundle" "$case_root/prep-scratch" > "$case_root/inspect.out"
  /usr/bin/cmp -s "$case_root/prepare.out" "$case_root/inspect.out" || fail "$name recovery envelope"
  make_description "$case_root/description.json" "$changed"
  "$python" -I "$helper" oracle check --description "$case_root/description.json" \
    --root "$case_root/output-parent/bundle/candidate" --algorithm "$algorithm" \
    --manifest "$case_root/output-parent/bundle/manifest.json" --root-mode 0500
  [ "$(sha_file "$producer_rev")" = "$producer_rev_sha" ] || fail "$name source sidecar changed"
  "$python" -B -I - "$case_root/materialized/repository.git" \
      "$case_root/output-parent/bundle/record.json" <<'PY'
import hashlib,json,os,stat,sys
from pathlib import Path
root,record=map(Path,sys.argv[1:])
rows=[]
for current,dirs,files in os.walk(root):
 for name in dirs+files:
  path=Path(current)/name; st=path.lstat(); rel=path.relative_to(root).as_posix()
  row={'path':rel,'type':'directory' if stat.S_ISDIR(st.st_mode) else 'file','mode':f'{stat.S_IMODE(st.st_mode):04o}'}
  if stat.S_ISREG(st.st_mode):
   data=path.read_bytes(); row.update(size_bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
  rows.append(row)
rows.sort(key=lambda row:row['path'].encode())
raw=(json.dumps(rows,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode()
assert json.loads(record.read_bytes())['storage_observation_sha256']==hashlib.sha256(raw).hexdigest()
PY
  [ -z "$(find "$case_root/output-parent/bundle" -name '*.rev' -print -quit)" ] || fail "$name sidecar published"
  pass "$name real materializer, exact export, and inspect"
  if [ "$name" = sha1-changed ]; then
    /bin/mkdir -m 700 "$case_root/no-sidecar-output" "$case_root/no-sidecar-scratch"
    make_no_sidecar_candidate "$case_root/materialized/repository.git" "$case_root/no-sidecar.git"
    [ -z "$(find "$case_root/no-sidecar.git" -name '*.rev' -print -quit)" ] || fail no-sidecar-source
    invoke_prepare prepare "$input" "$case_root/response.json" "$case_root/no-sidecar.git" \
      "$case_root/no-sidecar-output/bundle" "$case_root/no-sidecar-scratch" > "$case_root/no-sidecar.out"
    "$python" -B -I "$helper" oracle check --description "$case_root/description.json" \
      --root "$case_root/no-sidecar-output/bundle/candidate" --algorithm "$algorithm" \
      --manifest "$case_root/no-sidecar-output/bundle/manifest.json" --root-mode 0500 > /dev/null
    pass 'separately created loose-object candidate succeeds without optional sidecars'
  fi
}

build_case sha1-changed sha1 true
build_case sha1-nochange sha1 false
if git_clean init -q --bare --object-format=sha256 "$tmp/sha256-probe.git" 2>/dev/null; then
  build_case sha256-changed sha256 true
  build_case sha256-nochange sha256 false
else
  fail 'supported Git lacks SHA-256 object format'
fi

empty_case="$tmp/cases/empty-root"
/bin/mkdir -m 700 "$empty_case" "$empty_case/materialized" "$empty_case/materializer-scratch" \
  "$empty_case/prep-scratch" "$empty_case/output-parent" "$empty_case/source.git"
git_clean init -q --template="$tmp/empty-template" --bare "$empty_case/source.git"
empty_tree=$(printf '' | git_clean --git-dir="$empty_case/source.git" mktree)
empty_commit=$(printf 'empty root fixture\n' | \
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$empty_case/source.git" commit-tree "$empty_tree")
git_clean --git-dir="$empty_case/source.git" update-ref refs/heads/main "$empty_commit"
"$builder" build "$empty_case/fixture" "$jq_bin" sha1 "$empty_commit" "$empty_tree"
make_nochange_input "$empty_case/fixture/input.json" "$empty_case/input.json"
"$materializer" materialize "$empty_case/input.json" fixture.target "$empty_case/source.git" \
  "$empty_case/materialized" "$empty_case/materializer-scratch" "$tmp/object-closure" "$jq_bin" \
  > "$empty_case/response.json"
invoke_prepare prepare "$empty_case/input.json" "$empty_case/response.json" \
  "$empty_case/materialized/repository.git" "$empty_case/output-parent/bundle" \
  "$empty_case/prep-scratch" > "$empty_case/out"
printf '{"entries":[]}\n' > "$empty_case/description.json"
"$python" -B -I "$helper" oracle check --description "$empty_case/description.json" \
  --root "$empty_case/output-parent/bundle/candidate" --algorithm sha1 \
  --manifest "$empty_case/output-parent/bundle/manifest.json" --root-mode 0500 > /dev/null
pass 'real materializer and preparation preserve an empty root tree'

base="$tmp/cases/sha1-changed"
input="$base/fixture/input.json"
response="$base/response.json"
candidate="$base/materialized/repository.git"

for preserved in input candidate source prior-output; do
  case "$preserved" in
    input) preserved_path="$input" ;;
    candidate) preserved_path="$candidate" ;;
    source) preserved_path="$base/source.git" ;;
    prior-output) preserved_path="$base/output-parent/bundle" ;;
  esac
  "$python" -B -I "$helper" snapshot create --path "$preserved_path" \
    --snapshot "$tmp/$preserved.snapshot.json"
done

expect_error() {
  local name=$1 expected=$2 exit_code=$3; shift 3
  local actual case_root item preserve_index=0
  local -a preserved_paths=()
  case_root="$tmp/error-$name"
  /bin/mkdir -p "$case_root" "$case_root/scratch" "$case_root/output-parent"
  /bin/chmod 0700 "$case_root" "$case_root/scratch" "$case_root/output-parent"
  for item in "$@"; do
    if [[ "$item" == "$tmp/"* ]] && [ -e "$item" ] && [[ "$item" != "$case_root"* ]]; then
      "$python" -B -I "$helper" snapshot create --path "$item" \
        --snapshot "$case_root/preserved-$preserve_index.json"
      preserved_paths+=("$item")
      preserve_index=$((preserve_index + 1))
    fi
  done
  if "$@" > "$case_root/out" 2> "$case_root/err"; then
    fail "$name accepted"
  else
    actual=$?
  fi
  if [ "$actual" -ne "$exit_code" ] || [ -s "$case_root/out" ] || \
      [ "$(cat "$case_root/err")" != "$expected" ]; then
    printf 'FAIL detail: exit=%s stdout-bytes=%s stderr=' "$actual" "$(wc -c < "$case_root/out")" >&2
    /usr/bin/head -c 256 "$case_root/err" >&2
    printf '\n' >&2
    fail "$name result"
  fi
  preserve_index=0
  for item in "${preserved_paths[@]}"; do
    [ -e "$item" ] || fail "$name removed preserved input"
    "$python" -B -I "$helper" snapshot check --path "$item" \
      --snapshot "$case_root/preserved-$preserve_index.json"
    preserve_index=$((preserve_index + 1))
  done
  "$python" -B -I "$helper" snapshot check --path "$input" --snapshot "$tmp/input.snapshot.json"
  "$python" -B -I "$helper" snapshot check --path "$candidate" --snapshot "$tmp/candidate.snapshot.json"
  "$python" -B -I "$helper" snapshot check --path "$base/source.git" --snapshot "$tmp/source.snapshot.json"
  "$python" -B -I "$helper" snapshot check --path "$base/output-parent/bundle" \
    --snapshot "$tmp/prior-output.snapshot.json"
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
expect_error mixed-duplicate-option E_USAGE 2 "$python" -I "$component" prepare \
  --input="$input" --input "$input" --input-sha256 "$(sha_file "$input")" \
  --response "$response" --response-sha256 "$(sha_file "$response")" \
  --candidate-repository "$candidate" --output "$tmp/error-mixed-duplicate-option/output-parent/bundle" \
  --scratch "$tmp/error-mixed-duplicate-option/scratch" --jq "$jq_bin"
expect_error hostile-unknown-option E_USAGE 2 "$python" -I "$component" prepare \
  --hostile-$'line\nbreak' "$input" --input "$input" --input-sha256 "$(sha_file "$input")" \
  --response "$response" --response-sha256 "$(sha_file "$response")" \
  --candidate-repository "$candidate" --output "$tmp/error-hostile-unknown-option/output-parent/bundle" \
  --scratch "$tmp/error-hostile-unknown-option/scratch" --jq "$jq_bin"
expect_error missing-option E_USAGE 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(sha_file "$input")" --response "$response" \
  --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
  --output "$tmp/error-missing-option/output-parent/bundle" \
  --scratch "$tmp/error-missing-option/scratch"
expect_error extra-positional E_USAGE 2 "$python" -I "$component" prepare unexpected \
  --input "$input" --input-sha256 "$(sha_file "$input")" --response "$response" \
  --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
  --output "$tmp/error-extra-positional/output-parent/bundle" \
  --scratch "$tmp/error-extra-positional/scratch" --jq "$jq_bin"

for physical_case in relative repeated-separator dot-component; do
  case "$physical_case" in
    relative) bad_input=relative-input.json ;;
    repeated-separator) bad_input="${input%/*}//${input##*/}" ;;
    dot-component) bad_input="${input%/*}/./${input##*/}" ;;
  esac
  expect_error "physical-$physical_case" E_USAGE 2 "$python" -I "$component" prepare \
    --input "$bad_input" --input-sha256 "$(sha_file "$input")" --response "$response" \
    --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
    --output "$tmp/error-physical-$physical_case/output-parent/bundle" \
    --scratch "$tmp/error-physical-$physical_case/scratch" --jq "$jq_bin"
done

expect_error malformed-input-digest E_USAGE 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 not-a-digest --response "$response" \
  --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
  --output "$tmp/error-malformed-input-digest/output-parent/bundle" \
  --scratch "$tmp/error-malformed-input-digest/scratch" --jq "$jq_bin"
expect_error uppercase-response-digest E_USAGE 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(sha_file "$input")" --response "$response" \
  --response-sha256 "$(sha_file "$response" | /usr/bin/tr 'a-f' 'A-F')" \
  --candidate-repository "$candidate" --output "$tmp/error-uppercase-response-digest/output-parent/bundle" \
  --scratch "$tmp/error-uppercase-response-digest/scratch" --jq "$jq_bin"
expect_error wrong-response-hash E_IDENTITY 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(sha_file "$input")" --response "$response" \
  --response-sha256 "$(printf '%064d' 0)" --candidate-repository "$candidate" \
  --output "$tmp/error-wrong-response-hash/output-parent/bundle" \
  --scratch "$tmp/error-wrong-response-hash/scratch" --jq "$jq_bin"

bad_jq="$tmp/bad-jq"
/bin/cp "$jq_bin" "$bad_jq"
/bin/chmod 0700 "$bad_jq"
printf x | /bin/dd of="$bad_jq" bs=1 seek=0 conv=notrunc 2>/dev/null
/bin/chmod 0500 "$bad_jq"
expect_error altered-jq E_DEPENDENCY 1 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(sha_file "$input")" --response "$response" \
  --response-sha256 "$(sha_file "$response")" --candidate-repository "$candidate" \
  --output "$tmp/error-altered-jq/output-parent/bundle" \
  --scratch "$tmp/error-altered-jq/scratch" --jq "$bad_jq"

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
"$python" -B -I "$helper" depth-probes --component "$component"
"$python" -B -I "$helper" json-case --input "$input" --output "$tmp/mutated/depth-32.json" --case depth-32
expect_error json-depth-semantic E_INPUT 1 invoke_prepare prepare "$tmp/mutated/depth-32.json" \
  "$response" "$candidate" "$tmp/error-json-depth-semantic/output-parent/bundle" \
  "$tmp/error-json-depth-semantic/scratch"
for json_case in bom trailing duplicate-member nonfinite invalid-utf8; do
  "$python" -B -I "$helper" json-case --input "$input" \
    --output "$tmp/mutated/$json_case.json" --case "$json_case"
  expect_error "json-$json_case" E_INPUT 1 invoke_prepare prepare "$tmp/mutated/$json_case.json" \
    "$response" "$candidate" "$tmp/error-json-$json_case/output-parent/bundle" \
    "$tmp/error-json-$json_case/scratch"
done

for relation_case in request-ref candidate-commit parent-commit attempt-number receipt-extra response-authority \
    profile-ref source-repository outcome fake-receipt numeric-shape nested-shape; do
  "$python" -B -I "$helper" relation-case --input "$response" \
    --output "$tmp/mutated/relation-$relation_case.json" --case "$relation_case"
  expect_error "relation-$relation_case" E_INPUT 1 invoke_prepare prepare "$input" \
    "$tmp/mutated/relation-$relation_case.json" "$candidate" \
    "$tmp/error-relation-$relation_case/output-parent/bundle" \
    "$tmp/error-relation-$relation_case/scratch"
done

storage_copy="$tmp/storage-extra.git"
/bin/cp -R "$candidate" "$storage_copy"
/usr/bin/touch "$storage_copy/extra"
expect_error storage-extra E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_copy" \
  "$tmp/error-storage-extra/output-parent/bundle" "$tmp/error-storage-extra/scratch"

for hostile_case in hooks alternates; do
  hostile_repo="$tmp/storage-hostile-$hostile_case.git"
  hostile_sentinel="$tmp/hostile-$hostile_case-sentinel"
  /bin/cp -R "$candidate" "$hostile_repo"
  if [ "$hostile_case" = hooks ]; then
    /bin/mkdir -m 700 "$hostile_repo/hooks"
    printf '#!/bin/sh\ntouch %s\n' "$hostile_sentinel" > "$hostile_repo/hooks/reference-transaction"
    /bin/chmod 0500 "$hostile_repo/hooks/reference-transaction"
  else
    printf '%s\n' "$tmp/unrelated-object-store" > "$hostile_repo/objects/info/alternates"
    /bin/chmod 0400 "$hostile_repo/objects/info/alternates"
  fi
  expect_error "storage-hostile-$hostile_case" E_STORAGE 1 invoke_prepare prepare "$input" "$response" \
    "$hostile_repo" "$tmp/error-storage-hostile-$hostile_case/output-parent/bundle" \
    "$tmp/error-storage-hostile-$hostile_case/scratch"
  [ ! -e "$hostile_sentinel" ] || fail "hostile $hostile_case executed"
done

storage_link="$tmp/storage-directory-link.git"
/bin/cp -R "$candidate" "$storage_link"
/bin/ln -s ../info "$storage_link/objects/aa"
expect_error storage-directory-link E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_link" \
  "$tmp/error-storage-directory-link/output-parent/bundle" "$tmp/error-storage-directory-link/scratch"

storage_fifo="$tmp/storage-nonregular.git"
/bin/cp -R "$candidate" "$storage_fifo"
/usr/bin/mkfifo "$storage_fifo/objects/aa"
expect_error storage-nonregular E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_fifo" \
  "$tmp/error-storage-nonregular/output-parent/bundle" "$tmp/error-storage-nonregular/scratch"

bad_head="$tmp/storage-bad-head.git"
/bin/cp -R "$candidate" "$bad_head"
/bin/chmod 0600 "$bad_head/HEAD"
printf 'ref: refs/heads/../bad\n' > "$bad_head/HEAD"
/bin/chmod 0400 "$bad_head/HEAD"
expect_error storage-bad-head E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$bad_head" \
  "$tmp/error-storage-bad-head/output-parent/bundle" "$tmp/error-storage-bad-head/scratch"

for head_case in slash overlong; do
  head_repo="$tmp/storage-head-$head_case.git"
  /bin/cp -R "$candidate" "$head_repo"
  /bin/chmod 0600 "$head_repo/HEAD"
  if [ "$head_case" = slash ]; then
    printf 'ref: refs/heads/a/b\n' > "$head_repo/HEAD"
  else
    printf 'ref: refs/heads/%0129d\n' 0 > "$head_repo/HEAD"
  fi
  /bin/chmod 0400 "$head_repo/HEAD"
  expect_error "storage-head-$head_case" E_STORAGE 1 invoke_prepare prepare "$input" "$response" \
    "$head_repo" "$tmp/error-storage-head-$head_case/output-parent/bundle" \
    "$tmp/error-storage-head-$head_case/scratch"
done

for kind_case in info-file loose-directory; do
  kind_repo="$tmp/storage-kind-$kind_case.git"
  /bin/cp -R "$candidate" "$kind_repo"
  if [ "$kind_case" = info-file ]; then
    /bin/rmdir "$kind_repo/objects/info"; : > "$kind_repo/objects/info"
    /bin/chmod 0400 "$kind_repo/objects/info"
  else
    /bin/mkdir -p "$kind_repo/objects/aa"
    /bin/mkdir "$kind_repo/objects/aa/00000000000000000000000000000000000000"
  fi
  expect_error "storage-kind-$kind_case" E_STORAGE 1 invoke_prepare prepare "$input" "$response" \
    "$kind_repo" "$tmp/error-storage-kind-$kind_case/output-parent/bundle" \
    "$tmp/error-storage-kind-$kind_case/scratch"
done

bad_config="$tmp/storage-bad-config.git"
/bin/cp -R "$candidate" "$bad_config"
/bin/chmod 0600 "$bad_config/config"
/usr/bin/sed 's/repositoryformatversion = [01]/repositoryformatversion = 9/' \
  "$candidate/config" > "$bad_config/config"
/bin/chmod 0400 "$bad_config/config"
expect_error storage-bad-config E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$bad_config" \
  "$tmp/error-storage-bad-config/output-parent/bundle" "$tmp/error-storage-bad-config/scratch"

storage_hardlink="$tmp/storage-hardlink.git"
/bin/cp -R "$candidate" "$storage_hardlink"
linked_object=$(find "$storage_hardlink/objects" -type f ! -name '*.rev' -print -quit)
/bin/mkdir -p "$storage_hardlink/objects/aa"
/bin/ln "$linked_object" "$storage_hardlink/objects/aa/00000000000000000000000000000000000000"
expect_error storage-hardlink E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_hardlink" \
  "$tmp/error-storage-hardlink/output-parent/bundle" "$tmp/error-storage-hardlink/scratch"

storage_file_link="$tmp/storage-file-link.git"
/bin/cp -R "$candidate" "$storage_file_link"
/bin/ln -s ../../HEAD "$storage_file_link/objects/aa"
expect_error storage-file-link E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$storage_file_link" \
  "$tmp/error-storage-file-link/output-parent/bundle" "$tmp/error-storage-file-link/scratch"

unpaired_pack="$tmp/storage-unpaired-pack.git"
/bin/cp -R "$candidate" "$unpaired_pack"
unpaired_index=$(find "$unpaired_pack/objects/pack" -name '*.idx' -print -quit)
[ -n "$unpaired_index" ] || fail unpaired-index-absent
/bin/rm "$unpaired_index"
expect_error storage-unpaired-pack E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$unpaired_pack" \
  "$tmp/error-storage-unpaired-pack/output-parent/bundle" "$tmp/error-storage-unpaired-pack/scratch"

bad_bare="$tmp/storage-not-bare.git"
/bin/cp -R "$candidate" "$bad_bare"
/bin/chmod 0600 "$bad_bare/config"
/usr/bin/sed 's/bare = true/bare = false/' "$candidate/config" > "$bad_bare/config"
/bin/chmod 0400 "$bad_bare/config"
expect_error storage-not-bare E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$bad_bare" \
  "$tmp/error-storage-not-bare/output-parent/bundle" "$tmp/error-storage-not-bare/scratch"

reverse_copy="$tmp/storage-reverse.git"
/bin/cp -R "$candidate" "$reverse_copy"
reverse=$(find "$reverse_copy/objects/pack" -name '*.rev' -print -quit)
[ -n "$reverse" ] || fail reverse-index-copy-absent
/bin/chmod u+w "$reverse" || fail reverse-index-chmod
printf x | /bin/dd of="$reverse" bs=1 seek=0 conv=notrunc 2>/dev/null || fail reverse-index-write
expect_error reverse-index-corrupt E_STORAGE 1 invoke_prepare prepare "$input" "$response" "$reverse_copy" \
  "$tmp/error-reverse-index-corrupt/output-parent/bundle" "$tmp/error-reverse-index-corrupt/scratch"

for sidecar_case in linked nonregular oversize basename; do
  sidecar_repo="$tmp/storage-sidecar-$sidecar_case.git"
  /bin/cp -R "$candidate" "$sidecar_repo"
  sidecar=$(find "$sidecar_repo/objects/pack" -name '*.rev' -print -quit)
  /bin/rm "$sidecar"
  case "$sidecar_case" in
    linked) /bin/ln "${sidecar%.rev}.pack" "$sidecar" ;;
    nonregular) /usr/bin/mkfifo "$sidecar" ;;
    oversize) /usr/bin/yes x | /usr/bin/head -c 1048577 > "$sidecar" || : ;;
    basename) sidecar="$sidecar_repo/objects/pack/pack-0000000000000000000000000000000000000000.rev"; : > "$sidecar" ;;
  esac
  [ "$sidecar_case" = nonregular ] || /bin/chmod 0400 "$sidecar"
  sidecar_error=E_STORAGE; [ "$sidecar_case" = oversize ] && sidecar_error=E_LIMIT
  expect_error "storage-sidecar-$sidecar_case" "$sidecar_error" 1 invoke_prepare prepare "$input" "$response" \
    "$sidecar_repo" "$tmp/error-storage-sidecar-$sidecar_case/output-parent/bundle" \
    "$tmp/error-storage-sidecar-$sidecar_case/scratch"
done

for reverse_algorithm in sha1 sha256; do
  reverse_base="$tmp/cases/$reverse_algorithm-changed"
  reverse_input="$reverse_base/fixture/input.json"
  reverse_response="$reverse_base/response.json"
  for reverse_case in signature version hash-id duplicate-position swap-positions \
    out-of-range-position pack-checksum reverse-checksum truncate trailing; do
    malformed="$tmp/reverse-$reverse_algorithm-$reverse_case.git"
    /bin/cp -R "$reverse_base/materialized/repository.git" "$malformed"
    malformed_reverse=$(find "$malformed/objects/pack" -name '*.rev' -print -quit)
    "$python" -B -I "$helper" reverse-index mutate --algorithm "$reverse_algorithm" \
      --input "$malformed_reverse" --output "$tmp/mutated/$reverse_algorithm-$reverse_case.rev" \
      --case "$reverse_case" --rehash
    /bin/chmod u+w "$malformed_reverse"
    /bin/cp "$tmp/mutated/$reverse_algorithm-$reverse_case.rev" "$malformed_reverse"
    /bin/chmod 0400 "$malformed_reverse"
    expect_error "reverse-$reverse_algorithm-$reverse_case" E_STORAGE 1 invoke_prepare prepare \
      "$reverse_input" "$reverse_response" "$malformed" \
      "$tmp/error-reverse-$reverse_algorithm-$reverse_case/output-parent/bundle" \
      "$tmp/error-reverse-$reverse_algorithm-$reverse_case/scratch"
  done
done

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

stale_root="$tmp/stale-dependency-root"
/bin/mkdir -p "$stale_root/preparation/v1" "$stale_root/adapters/local-git-materializer/v1" \
  "$stale_root/scripts" "$stale_root/core/v2"
/bin/cp "$component" "$stale_root/preparation/v1/prepare-candidate.py"
/bin/cp "$root/adapters/local-git-materializer/v1/protocol.jq" "$stale_root/adapters/local-git-materializer/v1/"
/bin/cp "$root/scripts/core-contract.sh" "$stale_root/scripts/"
/bin/cp -R "$root/core/v2/generation-registry.json" "$root/core/v2/generations" "$stale_root/core/v2/"
printf '\n' >> "$stale_root/adapters/local-git-materializer/v1/protocol.jq"
expect_error stale-restoration-dependency E_DEPENDENCY 1 "$python" -I \
  "$stale_root/preparation/v1/prepare-candidate.py" inspect --input "$input" \
  --input-sha256 "$(sha_file "$input")" --response "$response" --response-sha256 "$(sha_file "$response")" \
  --candidate-repository "$candidate" --output "$restore/bundle" \
  --scratch "$tmp/error-stale-restoration-dependency/scratch" --jq "$jq_bin"

tampered="$tmp/tampered-candidate-bundle"
/bin/cp -R "$collision" "$tampered"
/bin/chmod 0700 "$tampered"
/bin/chmod 0600 "$tampered/candidate/source.txt" "$tampered/manifest.json" "$tampered/record.json"
printf 'omega\nbeta\ngamma\n' > "$tampered/candidate/source.txt"
"$python" -B -I - "$tampered" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
manifest=json.loads((root/'manifest.json').read_bytes())
entry=next(item for item in manifest['entries'] if item['path']=='source.txt')
entry['sha256']=hashlib.sha256((root/'candidate/source.txt').read_bytes()).hexdigest()
canonical=lambda value:(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode()
manifest_data=canonical(manifest); (root/'manifest.json').write_bytes(manifest_data)
record=json.loads((root/'record.json').read_bytes())
record['manifest_sha256']=hashlib.sha256(manifest_data).hexdigest()
(root/'record.json').write_bytes(canonical(record))
PY
/bin/chmod 0400 "$tampered/candidate/source.txt" "$tampered/manifest.json" "$tampered/record.json"
expect_error candidate-content-git-identity E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$tampered" "$tmp/error-candidate-content-git-identity/scratch"

for bundle_case in manifest-extra directory-extra file-mode-label blob-oid-label candidate-symlink candidate-hardlink; do
  malformed_bundle="$tmp/bundle-$bundle_case"
  /bin/cp -R "$collision" "$malformed_bundle"
  /bin/chmod 0700 "$malformed_bundle"
  case "$bundle_case" in
    manifest-*|directory-*|file-*|blob-*)
      /bin/chmod 0600 "$malformed_bundle/manifest.json" "$malformed_bundle/record.json"
      ;;
    candidate-*) /bin/chmod 0700 "$malformed_bundle/candidate" ;;
  esac
  "$python" -B -I - "$malformed_bundle" "$bundle_case" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
root,case=Path(sys.argv[1]),sys.argv[2]
canonical=lambda value:(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode()
manifest=json.loads((root/'manifest.json').read_bytes())
if case=='manifest-extra': manifest['unexpected']=False
elif case=='directory-extra': next(x for x in manifest['entries'] if x['kind']=='directory')['unexpected']=False
elif case=='file-mode-label': next(x for x in manifest['entries'] if x['kind']=='file')['mode']='0500'
elif case=='blob-oid-label':
    item=next(x for x in manifest['entries'] if x['kind']=='file'); item['blob_oid']='0'*len(item['blob_oid'])
elif case=='candidate-symlink':
    path=root/'candidate/source.txt'; path.unlink(); path.symlink_to('repeat-a.txt')
elif case=='candidate-hardlink':
    path=root/'candidate/source.txt'; other=root/'candidate/repeat-a.txt'; path.unlink(); os.link(other,path)
if case.startswith(('manifest','directory','file','blob')):
    data=canonical(manifest); (root/'manifest.json').write_bytes(data)
    record=json.loads((root/'record.json').read_bytes()); record['manifest_sha256']=hashlib.sha256(data).hexdigest()
    (root/'record.json').write_bytes(canonical(record))
PY
  case "$bundle_case" in
    manifest-*|directory-*|file-*|blob-*)
      /bin/chmod 0400 "$malformed_bundle/manifest.json" "$malformed_bundle/record.json"
      ;;
    candidate-*) /bin/chmod 0500 "$malformed_bundle/candidate" ;;
  esac
  expect_error "bundle-$bundle_case" E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
    "$malformed_bundle" "$tmp/error-bundle-$bundle_case/scratch"
done

extra_bundle="$tmp/extra-bundle"
/bin/cp -R "$collision" "$extra_bundle"
/bin/chmod 0700 "$extra_bundle"
/usr/bin/touch "$extra_bundle/unexpected"
expect_error extra-bundle-entry E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$extra_bundle" "$tmp/error-extra-bundle-entry/scratch"
corrupt_bundle="$tmp/corrupt-bundle"
/bin/cp -R "$collision" "$corrupt_bundle"
/bin/chmod 0700 "$corrupt_bundle"
/bin/chmod 0600 "$corrupt_bundle/record.json"
printf x >> "$corrupt_bundle/record.json"
/bin/chmod 0400 "$corrupt_bundle/record.json"
expect_error corrupt-record E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$corrupt_bundle" "$tmp/error-corrupt-record/scratch"

partial_bundle="$tmp/partial-bundle"
/bin/cp -R "$collision" "$partial_bundle"
/bin/chmod 0700 "$partial_bundle"
/bin/rm "$partial_bundle/record.json"
expect_error partial-bundle E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$partial_bundle" "$tmp/error-partial-bundle/scratch"

/bin/chmod 0600 "$restore/bundle/candidate/source.txt"
expect_error same-owner-mode-change E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$restore/bundle" "$tmp/error-same-owner-mode-change/scratch"

loose_source="$base/no-sidecar.git"
for object_case in missing corrupt truncated; do
  object_repo="$tmp/object-$object_case.git"
  /bin/cp -R "$loose_source" "$object_repo"
  object_oid=$(cat "$object_repo/refs/heads/candidate")
  object_file="$object_repo/objects/${object_oid:0:2}/${object_oid:2}"
  case "$object_case" in
    missing) /bin/rm "$object_file" ;;
    corrupt) /bin/chmod 0600 "$object_file"; printf x > "$object_file"; /bin/chmod 0400 "$object_file" ;;
    truncated)
      object_size=$(/usr/bin/wc -c < "$object_file")
      /usr/bin/head -c "$((object_size - 1))" "$object_file" > "$object_file.short"
      /bin/mv "$object_file.short" "$object_file"
      /bin/chmod 0400 "$object_file"
      ;;
  esac
  expect_error "object-$object_case" E_DEPENDENCY 1 invoke_prepare prepare "$input" "$response" \
    "$object_repo" "$tmp/error-object-$object_case/output-parent/bundle" \
    "$tmp/error-object-$object_case/scratch"
  [ ! -e "$tmp/error-object-$object_case/output-parent/bundle/record.json" ] || fail "object-$object_case published"
done

pass 'missing, corrupt, and truncated Git objects refuse without changing their repositories'

for raw_case in slash order mode prefix; do
  raw_repo="$tmp/raw-storage-$raw_case.git"
  raw_response="$tmp/mutated/raw-storage-$raw_case.json"
  /bin/cp -R "$loose_source" "$raw_repo"
  "$python" -B -I "$helper" raw-storage --repository "$raw_repo" --response "$response" \
    --output "$raw_response" --case "$raw_case"
  raw_error=E_OBJECT
  case "$raw_case" in slash|prefix) raw_error=E_PATH ;; esac
  expect_error "raw-storage-$raw_case" "$raw_error" 1 invoke_prepare prepare "$input" "$raw_response" \
    "$raw_repo" "$tmp/error-raw-storage-$raw_case/output-parent/bundle" \
    "$tmp/error-raw-storage-$raw_case/scratch"
done
pass 'malformed raw trees reach real object reading and targeted tree refusal'

for index_case in framing offset; do
  index_repo="$tmp/pack-index-$index_case.git"
  /bin/cp -R "$candidate" "$index_repo"
  index_file=$(find "$index_repo/objects/pack" -name '*.idx' -print -quit)
  pack_file=${index_file%.idx}.pack
  reverse_file=${index_file%.idx}.rev
  "$python" -B -I "$helper" pack-index --algorithm sha1 --index "$index_file" --pack "$pack_file" \
    --output-index "$tmp/mutated/pack-index-$index_case.idx" \
    --output-reverse "$tmp/mutated/pack-index-$index_case.rev" --case "$index_case"
  /bin/chmod 0600 "$index_file" "$reverse_file"
  /bin/cp "$tmp/mutated/pack-index-$index_case.idx" "$index_file"
  /bin/cp "$tmp/mutated/pack-index-$index_case.rev" "$reverse_file"
  /bin/chmod 0400 "$index_file" "$reverse_file"
  expect_error "pack-index-$index_case" E_STORAGE 1 invoke_prepare prepare "$input" "$response" \
    "$index_repo" "$tmp/error-pack-index-$index_case/output-parent/bundle" \
    "$tmp/error-pack-index-$index_case/scratch"
done
pass 'rehashed pack-index framing and offset mutations reach storage validation'

"$python" -I "$helper" limits > "$tmp/limits.json"
"$python" - "$tmp/limits.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))["limits"]
assert rows and all(row["inclusive"]+1==row["overflow"] for row in rows)
assert {"input_bytes","storage_bytes","blob_bytes","bundle_bytes"} <= {row["name"] for row in rows}
PY
pass 'inclusive limit ledger covers every named bound'
"$python" -B -I "$helper" raw-probes --component "$component"
pass 'raw tree framing, names, aliases, duplicate paths, and visit bound refuse'
"$python" -B -I "$helper" fault-probes --component "$component" --root "$tmp/fault-probes"
pass 'partial read/write, record rename, and nested directory fsync failures retain state'
"$python" -B -I "$helper" real-io --component "$component" --root "$tmp/real-file-io"
pass 'kernel file-open and file-create exhaustion refuse with preserved state'

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

public_root="$tmp/public-parent"
/bin/mkdir -m 755 "$public_root" "$public_root/scratch" "$public_root/output-parent"
expect_error public-directory-leaf E_IDENTITY 2 "$python" -I "$component" prepare \
  --input "$input" --input-sha256 "$(sha_file "$input")" \
  --response "$response" --response-sha256 "$(sha_file "$response")" \
  --candidate-repository "$candidate" --output "$public_root/output-parent/bundle" \
  --scratch "$public_root/scratch" --jq "$jq_bin"

"$python" -B -I "$helper" supervised-probe --component "$component" --probe child-setup-cleanup
pass 'post-spawn selector setup failure terminates and reaps its child'
"$python" -B -I "$helper" supervised-probe --component "$component" --probe child-streaming
pass 'child output streams in bounded chunks and deadline children are reaped'

race="$tmp/output-race"
/bin/mkdir -m 700 "$race" "$race/scratch" "$race/output-parent" "$race/sentinel"
"$python" - "$race/argv.json" "$input" "$response" "$candidate" "$race" "$jq_bin" <<'PY'
import hashlib,json,sys
out,inp,response,candidate,root,jq=sys.argv[1:]
sha=lambda p:hashlib.sha256(open(p,"rb").read()).hexdigest()
argv=["prepare","--input",inp,"--input-sha256",sha(inp),"--response",response,
      "--response-sha256",sha(response),"--candidate-repository",candidate,
      "--output",root+"/output-parent/bundle","--scratch",root+"/scratch","--jq",jq]
open(out,"w").write(json.dumps(argv))
PY
"$python" -B -I "$helper" inject --component "$component" --target publish_record \
  --mode before-pause --ready "$race/ready" --release "$race/release" \
  --argv-json "$race/argv.json" > "$race/out" 2> "$race/err" &
race_pid=$!
for _ in $(seq 1 300); do
  [ -f "$race/ready" ] && break
  kill -0 "$race_pid" 2>/dev/null || break
  sleep 0.1
done
[ -f "$race/ready" ] || fail output-race-ready
/bin/mv "$race/output-parent/bundle" "$race/output-parent/held-bundle"
/bin/ln -s "$race/sentinel" "$race/output-parent/bundle"
: > "$race/release"
if wait_bounded "$race_pid"; then
  fail output-race-accepted
else
  race_status=$?
fi
[ "$race_status" -eq 2 ] && [ ! -s "$race/out" ] && \
  [ "$(cat "$race/err")" = E_IDENTITY ] || fail output-race-result
[ -z "$(find "$race/sentinel" -mindepth 1 -print -quit)" ] || fail output-race-escaped-write
[ -f "$race/output-parent/held-bundle/record.json" ] || fail output-race-held-record
pass 'output replacement is detected and descriptor-bound publication cannot escape'

read_race="$tmp/inspect-read-race"
/bin/mkdir -m 700 "$read_race" "$read_race/scratch" "$read_race/replacement"
/bin/cp -R "$collision" "$read_race/bundle"; /bin/chmod 0700 "$read_race/bundle"
"$python" - "$read_race/argv.json" "$input" "$response" "$candidate" "$read_race" "$jq_bin" <<'PY'
import hashlib,json,sys
out,inp,response,candidate,root,jq=sys.argv[1:]
sha=lambda p:hashlib.sha256(open(p,'rb').read()).hexdigest()
json.dump(['inspect','--input',inp,'--input-sha256',sha(inp),'--response',response,
 '--response-sha256',sha(response),'--candidate-repository',candidate,'--output',root+'/bundle',
 '--scratch',root+'/scratch','--jq',jq],open(out,'w'))
PY
"$python" -B -I "$helper" inject --component "$component" --target read_output_file \
  --mode before-pause --ready "$read_race/ready" --release "$read_race/release" \
  --argv-json "$read_race/argv.json" > "$read_race/out" 2> "$read_race/err" &
read_race_pid=$!
for _ in $(seq 1 300); do [ -f "$read_race/ready" ] && break; sleep 0.1; done
[ -f "$read_race/ready" ] || fail inspect-read-race-ready
/bin/mv "$read_race/bundle" "$read_race/held-bundle"
"$python" -B -I "$helper" snapshot create --path "$read_race/held-bundle" \
  --snapshot "$read_race/held.snapshot.json"
/usr/bin/yes x | /usr/bin/head -c 8388609 > "$read_race/replacement/input.json" || :
/bin/ln -s "$read_race/replacement" "$read_race/bundle"; : > "$read_race/release"
if wait_bounded "$read_race_pid"; then fail inspect-read-race-accepted; else read_race_status=$?; fi
[ "$read_race_status" -eq 2 ] && [ ! -s "$read_race/out" ] && \
  [ "$(cat "$read_race/err")" = E_IDENTITY ] || fail inspect-read-race-result
"$python" -B -I "$helper" snapshot check --path "$read_race/held-bundle" \
  --snapshot "$read_race/held.snapshot.json"
pass 'inspect metadata reads stay under the held bundle descriptor'

write_argv() {
  local destination=$1 case_root=$2 case_input=${3:-$input} case_candidate=${4:-$candidate}
  "$python" - "$destination" "$case_input" "$response" "$case_candidate" "$case_root" "$jq_bin" <<'PY'
import hashlib,json,sys
out,inp,response,candidate,root,jq=sys.argv[1:]
sha=lambda p:hashlib.sha256(open(p,"rb").read()).hexdigest()
argv=["prepare","--input",inp,"--input-sha256",sha(inp),"--response",response,
      "--response-sha256",sha(response),"--candidate-repository",candidate,
      "--output",root+"/output-parent/bundle","--scratch",root+"/scratch","--jq",jq]
open(out,"w").write(json.dumps(argv))
PY
}

accounting_root="$tmp/storage-accounting"
/bin/mkdir -m 700 "$accounting_root"
"$python" -B -I - "$accounting_root/ballast" <<'PY'
import hashlib,sys
remaining=9*1024*1024
with open(sys.argv[1],"wb") as stream:
 for counter in range((remaining+31)//32):
  block=hashlib.sha256(counter.to_bytes(8,"big")).digest()
  chunk=block[:remaining]; stream.write(chunk); remaining-=len(chunk)
PY
for accounting_case in baseline inclusive overflow; do
  accounting_case_root="$accounting_root/$accounting_case"
  /bin/mkdir -p "$accounting_case_root/scratch" "$accounting_case_root/output-parent"
  /bin/chmod 0700 "$accounting_root" "$accounting_case_root" \
    "$accounting_case_root/scratch" "$accounting_case_root/output-parent"
  accounting_candidate="$accounting_case_root/candidate.git"
  /bin/cp -R "$candidate" "$accounting_candidate"
  find "$accounting_candidate" -type d -exec /bin/chmod 0700 {} +
  find "$accounting_candidate" -type f -exec /bin/chmod 0400 {} +
  ballast_oid=$("$python" -B -I "$helper" object --repository "$accounting_candidate" \
    --algorithm sha1 --type blob --body "$accounting_root/ballast")
  /bin/chmod 0400 "$accounting_candidate/objects/${ballast_oid:0:2}/${ballast_oid:2}"
  write_argv "$accounting_case_root/argv.json" "$accounting_case_root" "$input" "$accounting_candidate"
done
if ! "$python" -B -I "$helper" accounting-probes --component "$component" \
    --argv-json "$accounting_root/baseline/argv.json" \
    --inclusive-argv-json "$accounting_root/inclusive/argv.json" \
    --overflow-argv-json "$accounting_root/overflow/argv.json" \
    > "$accounting_root/out" 2> "$accounting_root/err"; then
  /bin/cat "$accounting_root/out" "$accounting_root/err" >&2
  fail storage-accounting-probe
fi
[ -f "$accounting_root/baseline/output-parent/bundle/record.json" ] && \
  [ -f "$accounting_root/inclusive/output-parent/bundle/record.json" ] && \
  [ "$(cat "$accounting_root/err")" = E_LIMIT ] || fail storage-accounting-result
pass 'actual retained storage controls the inclusive scratch peak and peak minus one refuses during copy'

wait_ready() {
  local ready=$1 pid=$2
  for ((ready_wait=0; ready_wait<300; ready_wait++)); do
    [ -f "$ready" ] && return
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || :
  wait_bounded "$pid" 2>/dev/null || :
  fail "pause not reached: $ready"
}

for io_case in mkdir-output mkdir-scratch; do
  io_root="$tmp/real-$io_case"
  /bin/mkdir -m 700 "$io_root" "$io_root/scratch" "$io_root/output-parent"
  if [ "$io_case" = mkdir-output ]; then
    /bin/chmod 0500 "$io_root/output-parent"
  else
    /bin/chmod 0500 "$io_root/scratch"
  fi
  if invoke_prepare prepare "$input" "$response" "$candidate" "$io_root/output-parent/bundle" \
      "$io_root/scratch" > "$io_root/out" 2> "$io_root/err"; then
    fail "$io_case accepted"
  else
    io_status=$?
  fi
  [ "$io_status" -eq 1 ] && [ ! -s "$io_root/out" ] && [ "$(cat "$io_root/err")" = E_IO ] || \
    fail "$io_case result"
  pass "real $io_case permission failure emits no success"
done

pipe_root="$tmp/os-broken-pipe"
/bin/mkdir -m 700 "$pipe_root" "$pipe_root/scratch" "$pipe_root/output-parent"
write_argv "$pipe_root/argv.json" "$pipe_root"
"$python" -B -I "$helper" closed-pipe --component "$component" --argv-json "$pipe_root/argv.json"
[ -f "$pipe_root/output-parent/bundle/record.json" ] || fail os-broken-pipe-state
pass 'actual closed OS reply pipe refuses after retaining a complete bundle'

deadline_root="$tmp/operation-deadline"
/bin/mkdir -m 700 "$deadline_root" "$deadline_root/scratch" "$deadline_root/output-parent"
write_argv "$deadline_root/argv.json" "$deadline_root"
if "$python" -B -I "$helper" limit-invoke --component "$component" --name operation_seconds \
    --value 0 --argv-json "$deadline_root/argv.json" > "$deadline_root/out" 2> "$deadline_root/err"; then
  fail operation-deadline-accepted
else
  deadline_status=$?
fi
[ "$deadline_status" -eq 75 ] && [ ! -s "$deadline_root/out" ] && \
  [ "$(cat "$deadline_root/err")" = E_TIMEOUT ] && \
  [ -z "$(find "$deadline_root/scratch" -mindepth 1 -print -quit)" ] || fail operation-deadline-result
pass 'operation deadline refuses cleanly before retaining work or children'

for replacement_case in input repository; do
  replacement_root="$tmp/$replacement_case-replacement"
  replacement_input="$replacement_root/input.json"; replacement_repo="$replacement_root/candidate.git"
  /bin/mkdir -m 700 "$replacement_root" "$replacement_root/scratch" "$replacement_root/output-parent"
  /bin/cp "$input" "$replacement_input"; /bin/cp -R "$candidate" "$replacement_repo"
  write_argv "$replacement_root/argv.json" "$replacement_root" "$replacement_input" "$replacement_repo"
  if [ "$replacement_case" = input ]; then target=load_identity_inputs; replaced=$replacement_input
  else target=copy_storage; replaced=$replacement_repo
  fi
  "$python" -B -I "$helper" inject --component "$component" --target "$target" --mode after-pause \
    --ready "$replacement_root/ready" --release "$replacement_root/release" \
    --argv-json "$replacement_root/argv.json" > "$replacement_root/out" 2> "$replacement_root/err" &
  replacement_pid=$!; wait_ready "$replacement_root/ready" "$replacement_pid"
  /bin/mv "$replaced" "$replaced.held"
  if [ "$replacement_case" = input ]; then /bin/cp "$replaced.held" "$replaced"
  else /bin/cp -R "$replaced.held" "$replaced"
  fi
  "$python" -B -I "$helper" snapshot create --path "$replaced.held" \
    --snapshot "$replacement_root/held.snapshot.json"
  : > "$replacement_root/release"
  if wait_bounded "$replacement_pid"; then fail "$replacement_case replacement accepted"; else replacement_status=$?; fi
  [ "$replacement_status" -eq 2 ] && [ ! -s "$replacement_root/out" ] && \
    [ "$(cat "$replacement_root/err")" = E_IDENTITY ] || fail "$replacement_case replacement result"
  "$python" -B -I "$helper" snapshot check --path "$replaced.held" \
    --snapshot "$replacement_root/held.snapshot.json"
  pass "$replacement_case replacement is detected without mutating the admitted input"
done

mutated_input="$tmp/input-mutation"
/bin/cp "$input" "$mutated_input"
/bin/chmod 0600 "$mutated_input"
input_race="$tmp/input-race"
/bin/mkdir -m 700 "$input_race" "$input_race/scratch" "$input_race/output-parent"
write_argv "$input_race/argv.json" "$input_race" "$mutated_input"
"$python" -B -I "$helper" inject --component "$component" --target load_identity_inputs \
  --mode after-pause --ready "$input_race/ready" --release "$input_race/release" \
  --argv-json "$input_race/argv.json" > "$input_race/out" 2> "$input_race/err" &
input_race_pid=$!
wait_ready "$input_race/ready" "$input_race_pid"
"$python" -B -I - "$mutated_input" <<'PY'
import os,sys
p=sys.argv[1]; data=bytearray(open(p,'rb').read()); data[10]^=1
with open(p,'r+b',buffering=0) as stream: stream.write(data)
PY
: > "$input_race/release"
if wait_bounded "$input_race_pid"; then fail input-mutation-accepted; else input_race_status=$?; fi
[ "$input_race_status" -eq 2 ] && [ ! -s "$input_race/out" ] && \
  [ "$(cat "$input_race/err")" = E_IDENTITY ] || fail input-mutation-result
pass 'same-inode supplied-input mutation is rehashed before completion'

source_race="$tmp/source-race"
source_race_repo="$source_race/candidate.git"
/bin/mkdir -m 700 "$source_race" "$source_race/scratch" "$source_race/output-parent"
/bin/cp -R "$candidate" "$source_race_repo"
write_argv "$source_race/argv.json" "$source_race" "$input" "$source_race_repo"
"$python" -B -I "$helper" inject --component "$component" --target copy_storage \
  --mode after-pause --ready "$source_race/ready" --release "$source_race/release" \
  --argv-json "$source_race/argv.json" > "$source_race/out" 2> "$source_race/err" &
source_race_pid=$!
wait_ready "$source_race/ready" "$source_race_pid"
source_object=$(find "$source_race_repo/objects" -type f ! -name '*.rev' -print -quit)
/bin/chmod 0600 "$source_object"
"$python" -B -I - "$source_object" <<'PY'
import os,sys
p=sys.argv[1]; data=bytearray(open(p,'rb').read()); data[-1]^=1
st=os.stat(p)
with open(p,'r+b',buffering=0) as stream: stream.write(data)
os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns))
PY
/bin/chmod 0400 "$source_object"
: > "$source_race/release"
if wait_bounded "$source_race_pid"; then fail source-mutation-accepted; else source_race_status=$?; fi
[ "$source_race_status" -eq 1 ] && [ ! -s "$source_race/out" ] && \
  [ "$(cat "$source_race/err")" = E_STORAGE ] || fail source-mutation-result
pass 'same-inode source mutation with restored timestamp is remeasured'

sidecar_race="$tmp/sidecar-mutation-race"; sidecar_race_repo="$sidecar_race/candidate.git"
/bin/mkdir -m 700 "$sidecar_race" "$sidecar_race/scratch" "$sidecar_race/output-parent"
/bin/cp -R "$candidate" "$sidecar_race_repo"
write_argv "$sidecar_race/argv.json" "$sidecar_race" "$input" "$sidecar_race_repo"
"$python" -B -I "$helper" inject --component "$component" --target copy_storage --mode after-pause \
  --ready "$sidecar_race/ready" --release "$sidecar_race/release" \
  --argv-json "$sidecar_race/argv.json" > "$sidecar_race/out" 2> "$sidecar_race/err" &
sidecar_race_pid=$!; wait_ready "$sidecar_race/ready" "$sidecar_race_pid"
sidecar_race_file=$(find "$sidecar_race_repo/objects/pack" -name '*.rev' -print -quit)
/bin/chmod 0600 "$sidecar_race_file"; printf x >> "$sidecar_race_file"; /bin/chmod 0400 "$sidecar_race_file"
: > "$sidecar_race/release"
if wait_bounded "$sidecar_race_pid"; then fail sidecar-mutation-accepted; else sidecar_race_status=$?; fi
[ "$sidecar_race_status" -eq 1 ] && [ ! -s "$sidecar_race/out" ] && \
  [ "$(cat "$sidecar_race/err")" = E_STORAGE ] || fail sidecar-mutation-result
pass 'source reverse-index mutation after copying is rejected on final reread'

for reservation_case in unchanged grown; do
  reservation_root="$tmp/source-reservation-$reservation_case"
  reservation_repo="$reservation_root/candidate.git"
  /bin/mkdir -m 700 "$reservation_root" "$reservation_root/scratch" "$reservation_root/output-parent"
  /bin/cp -R "$candidate" "$reservation_repo"
  reservation_object=$(find "$reservation_repo/objects" -type f ! -name '*.rev' -print -quit)
  reservation_size=$(wc -c < "$reservation_object" | tr -d ' ')
  write_argv "$reservation_root/argv.json" "$reservation_root" "$input" "$reservation_repo"
  "$python" -B -I "$helper" inject --component "$component" --target copy_storage \
    --mode before-pause --ready "$reservation_root/ready" --release "$reservation_root/release" \
    --argv-json "$reservation_root/argv.json" > "$reservation_root/out" 2> "$reservation_root/err" &
  reservation_pid=$!
  wait_ready "$reservation_root/ready" "$reservation_pid"
  if [ "$reservation_case" = grown ]; then
    /bin/chmod 0600 "$reservation_object"; printf x >> "$reservation_object"; /bin/chmod 0400 "$reservation_object"
  fi
  : > "$reservation_root/release"
  if wait_bounded "$reservation_pid"; then reservation_status=0; else reservation_status=$?; fi
  if [ "$reservation_case" = unchanged ]; then
    [ "$reservation_status" -eq 0 ] && [ -s "$reservation_root/out" ] || fail reservation-control
  else
    [ "$reservation_status" -eq 1 ] && [ ! -s "$reservation_root/out" ] && \
      [ "$(cat "$reservation_root/err")" = E_LIMIT ] || fail reservation-growth-result
    copied_object=$(find "$reservation_root/scratch" -path '*/candidate.git/objects/*/*' -type f -print -quit)
    [ -z "$copied_object" ] || [ "$(wc -c < "$copied_object" | tr -d ' ')" -le "$reservation_size" ] || \
      fail reservation-growth-write
  fi
  pass "source copy reservation $reservation_case control"
done

for source_change in add remove; do
  change_root="$tmp/source-$source_change-race"
  change_repo="$change_root/candidate.git"
  /bin/mkdir -m 700 "$change_root" "$change_root/scratch" "$change_root/output-parent"
  /bin/cp -R "$candidate" "$change_repo"
  write_argv "$change_root/argv.json" "$change_root" "$input" "$change_repo"
  "$python" -B -I "$helper" inject --component "$component" --target copy_storage \
    --mode after-pause --ready "$change_root/ready" --release "$change_root/release" \
    --argv-json "$change_root/argv.json" > "$change_root/out" 2> "$change_root/err" &
  change_pid=$!
  wait_ready "$change_root/ready" "$change_pid"
  if [ "$source_change" = add ]; then
    /bin/mkdir -m 700 "$change_repo/objects/aa"
    printf x > "$change_repo/objects/aa/00000000000000000000000000000000000000"
    /bin/chmod 0400 "$change_repo/objects/aa/00000000000000000000000000000000000000"
  else
    removed_source=$(find "$change_repo/objects" -type f ! -name '*.rev' -print -quit)
    /bin/rm "$removed_source"
  fi
  : > "$change_root/release"
  if wait_bounded "$change_pid"; then fail "source $source_change accepted"; else change_status=$?; fi
  [ "$change_status" -eq 1 ] && [ ! -s "$change_root/out" ] && \
    [ "$(cat "$change_root/err")" = E_STORAGE ] || fail "source $source_change result"
  pass "source entry $source_change during preparation is detected"
done

for fault_target in fsync_file publish_record fsync_dir; do
  fault="$tmp/io-fault-$fault_target"
  /bin/mkdir -m 700 "$fault" "$fault/scratch" "$fault/output-parent"
  write_argv "$fault/argv.json" "$fault"
  if "$python" -B -I "$helper" inject --component "$component" --target "$fault_target" \
      --mode before-error --argv-json "$fault/argv.json" > "$fault/out" 2> "$fault/err"; then
    fail "$fault_target fault accepted"
  else
    fault_status=$?
  fi
  [ "$fault_status" -eq 1 ] && [ ! -s "$fault/out" ] && [ "$(cat "$fault/err")" = E_IO ] || \
    fail "$fault_target fault result"
  pass "$fault_target failure emits no success and preserves the attempt"
done

for post_target in publish_record fsync_dir; do
  post="$tmp/post-publication-$post_target"
  /bin/mkdir -m 700 "$post" "$post/scratch" "$post/inspect-scratch" "$post/output-parent"
  write_argv "$post/argv.json" "$post"
  if "$python" -B -I "$helper" inject --component "$component" --target "$post_target" \
      --mode after-error --argv-json "$post/argv.json" > "$post/out" 2> "$post/err"; then
    fail "$post_target post-publication fault accepted"
  else
    post_status=$?
  fi
  [ "$post_status" -eq 1 ] && [ ! -s "$post/out" ] && [ "$(cat "$post/err")" = E_IO ] && \
    [ -f "$post/output-parent/bundle/record.json" ] || fail "$post_target post-publication state"
  invoke_prepare inspect "$input" "$response" "$candidate" "$post/output-parent/bundle" \
    "$post/inspect-scratch" > "$post/recovered"
  pass "$post_target post-publication failure preserves inspectable completion"
done

before_record="$tmp/kill-before-record"
/bin/mkdir -m 700 "$before_record" "$before_record/scratch" "$before_record/output-parent"
write_argv "$before_record/argv.json" "$before_record"
"$python" -B -I "$helper" inject --component "$component" --target export_candidate \
  --mode after-pause --ready "$before_record/ready" --release "$before_record/release" \
  --argv-json "$before_record/argv.json" > "$before_record/out" 2> "$before_record/err" &
before_pid=$!
wait_ready "$before_record/ready" "$before_pid"
kill -KILL "$before_pid"
if wait_bounded "$before_pid" 2>/dev/null; then fail kill-before-record-status; else before_status=$?; fi
[ "$before_status" -eq 137 ] && [ ! -s "$before_record/out" ] && \
  [ ! -e "$before_record/output-parent/bundle/record.json" ] || fail kill-before-record-state
expect_error killed-incomplete E_INCOMPLETE 1 invoke_prepare inspect "$input" "$response" "$candidate" \
  "$before_record/output-parent/bundle" "$tmp/error-killed-incomplete/scratch"
pass 'SIGKILL after export retains an incomplete bundle without a receipt'

after_record="$tmp/kill-after-record"
/bin/mkdir -m 700 "$after_record" "$after_record/scratch" "$after_record/output-parent"
write_argv "$after_record/argv.json" "$after_record"
"$python" -B -I "$helper" inject --component "$component" --target emit_result \
  --mode before-pause --ready "$after_record/ready" --release "$after_record/release" \
  --argv-json "$after_record/argv.json" > "$after_record/out" 2> "$after_record/err" &
after_pid=$!
wait_ready "$after_record/ready" "$after_pid"
[ ! -s "$after_record/out" ] && [ -f "$after_record/output-parent/bundle/record.json" ] || \
  fail kill-after-record-boundary
/bin/mkdir -m 700 "$after_record/inspect-scratch"
invoke_prepare inspect "$input" "$response" "$candidate" "$after_record/output-parent/bundle" \
  "$after_record/inspect-scratch" > "$after_record/waiting-inspect" 2> "$after_record/waiting-inspect.err" &
waiting_inspect_pid=$!
sleep 0.5
kill -0 "$waiting_inspect_pid" 2>/dev/null || fail pre-reply-lock-released
[ ! -s "$after_record/waiting-inspect" ] && [ ! -s "$after_record/waiting-inspect.err" ] || \
  fail pre-reply-inspect-emitted
kill -KILL "$after_pid"
if wait_bounded "$after_pid" 2>/dev/null; then fail kill-after-record-status; else after_status=$?; fi
[ "$after_status" -eq 137 ] || fail kill-after-record-exit
wait_bounded "$waiting_inspect_pid" || fail pre-reply-inspect-status
invoke_prepare inspect "$input" "$response" "$candidate" "$after_record/output-parent/bundle" \
  "$after_record/scratch" > "$after_record/recovered-1"
invoke_prepare inspect "$input" "$response" "$candidate" "$after_record/output-parent/bundle" \
  "$after_record/scratch" > "$after_record/recovered-2"
/usr/bin/cmp -s "$after_record/recovered-1" "$after_record/recovered-2" || fail kill-recovery-envelope
pass 'SIGKILL after publication emits nothing and inspect recovers identically'

handled="$tmp/handled-signal"
/bin/mkdir -m 700 "$handled" "$handled/scratch" "$handled/output-parent"
write_argv "$handled/argv.json" "$handled"
"$python" -B -I "$helper" inject --component "$component" --target export_candidate \
  --mode after-pause --ready "$handled/ready" --release "$handled/release" \
  --argv-json "$handled/argv.json" > "$handled/out" 2> "$handled/err" &
handled_pid=$!
wait_ready "$handled/ready" "$handled_pid"
kill -TERM "$handled_pid"
if wait_bounded "$handled_pid"; then fail handled-signal-status; else handled_status=$?; fi
[ "$handled_status" -eq 75 ] && [ ! -s "$handled/out" ] && \
  [ "$(cat "$handled/err")" = E_INTERRUPTED ] || fail handled-signal-result
pass 'handled termination returns the bounded interruption refusal'

broken="$tmp/broken-reply"
/bin/mkdir -m 700 "$broken" "$broken/scratch" "$broken/output-parent"
write_argv "$broken/argv.json" "$broken"
if "$python" -B -I "$helper" inject --component "$component" --target emit_result \
    --mode before-error --argv-json "$broken/argv.json" > "$broken/out" 2> "$broken/err"; then
  fail broken-reply-status
else
  broken_status=$?
fi
[ "$broken_status" -eq 1 ] && [ ! -s "$broken/out" ] && [ "$(cat "$broken/err")" = E_IO ] || \
  fail broken-reply-result
invoke_prepare inspect "$input" "$response" "$candidate" "$broken/output-parent/bundle" \
  "$broken/scratch" > "$broken/recovered"
pass 'broken outward reply preserves a complete inspectable bundle'

locked="$tmp/lock-serialization"
/bin/mkdir -m 700 "$locked" "$locked/scratch" "$locked/inspect-scratch" "$locked/output-parent"
write_argv "$locked/argv.json" "$locked"
"$python" -B -I "$helper" inject --component "$component" --target publish_record \
  --mode after-pause --ready "$locked/ready" --release "$locked/release" \
  --argv-json "$locked/argv.json" > "$locked/prepare.out" 2> "$locked/prepare.err" &
prepare_pid=$!
wait_ready "$locked/ready" "$prepare_pid"
invoke_prepare inspect "$input" "$response" "$candidate" "$locked/output-parent/bundle" \
  "$locked/inspect-scratch" > "$locked/inspect.out" 2> "$locked/inspect.err" &
inspect_pid=$!
sleep 0.5
kill -0 "$inspect_pid" 2>/dev/null || fail inspect-did-not-wait-for-lock
[ ! -s "$locked/inspect.out" ] && [ ! -s "$locked/inspect.err" ] || fail inspect-emitted-while-locked
: > "$locked/release"
wait_bounded "$prepare_pid" || fail locked-prepare-status
wait_bounded "$inspect_pid" || fail locked-inspect-status
/usr/bin/cmp -s "$locked/prepare.out" "$locked/inspect.out" || fail locked-envelope
pass 'inspect serializes behind the active preparation lock'

limit_pair() {
  local name=$1 maximum=$2 expected=${3:-E_LIMIT} limit_root overflow_root
  limit_root="$tmp/limit-$name"
  overflow_root="$tmp/limit-$name-overflow"
  /bin/mkdir -m 700 "$limit_root" "$limit_root/scratch" "$limit_root/output-parent" \
    "$overflow_root" "$overflow_root/scratch" "$overflow_root/output-parent"
  write_argv "$limit_root/argv.json" "$limit_root"
  write_argv "$overflow_root/argv.json" "$overflow_root"
  "$python" -B -I "$helper" limit-invoke --component "$component" --name "$name" \
    --value "$maximum" --argv-json "$limit_root/argv.json" > "$limit_root/out" 2> "$limit_root/err" || \
    fail "$name inclusive limit"
  if "$python" -B -I "$helper" limit-invoke --component "$component" --name "$name" \
      --value "$((maximum - 1))" --argv-json "$overflow_root/argv.json" \
      > "$overflow_root/out" 2> "$overflow_root/err"; then
    fail "$name overflow accepted"
  else
    limit_status=$?
  fi
  [ "$limit_status" -eq 1 ] && [ ! -s "$overflow_root/out" ] && \
    [ "$(cat "$overflow_root/err")" = "$expected" ] || fail "$name overflow result"
  pass "$name admits its actual inclusive fixture and rejects one byte less"
}

read -r input_size response_size storage_size repository_file_size reverse_size repository_entries \
  repository_name_bytes blob_size export_size file_paths directory_count export_path_bytes bundle_size \
  manifest_size record_size result_size head_size config_size receipt_size stage_size dependency_size \
  commit_size tree_size tree_bytes tree_visits tree_entries reverse_objects < <(
  "$python" -B -I - "$input" "$response" "$candidate" "$collision" "$jq_bin" <<'PY'
import json,os,subprocess,sys
from pathlib import Path
inp,response,candidate,bundle=map(Path,sys.argv[1:5]); jq=Path(sys.argv[5])
repo=Path.cwd(); response_value=json.loads(response.read_bytes())
files=lambda root:[p.stat().st_size for p in root.rglob("*") if p.is_file()]
relative=lambda root,p:p.relative_to(root).as_posix()
storage_files=[p for p in candidate.rglob('*') if p.is_file()]
storage_entries=[p for p in candidate.rglob('*')]
export_files=[p for p in (bundle/'candidate').rglob('*') if p.is_file()]
export_dirs=[p for p in (bundle/'candidate').rglob('*') if p.is_dir()]
export_entries=export_files+export_dirs
git=lambda *args:subprocess.check_output(['/usr/bin/git','--git-dir',str(candidate),*args]).decode().strip()
commit=git('rev-parse','refs/heads/candidate'); tree=git('show','-s','--format=%T',commit)
tree_rows=git('ls-tree','-r','-t',tree).splitlines()
trees=[tree]+[row.split()[2] for row in tree_rows if row.split()[1]=='tree']
reverse=next(p for p in storage_files if p.suffix=='.rev'); oid_bytes=len(commit)//2
print(inp.stat().st_size,response.stat().st_size,sum(p.stat().st_size for p in storage_files),
      max(p.stat().st_size for p in storage_files),
      max(p.stat().st_size for p in storage_files if p.suffix=='.rev'),len(storage_entries),
      sum(len(relative(candidate,p).encode()) for p in storage_entries),
      max(p.stat().st_size for p in export_files),sum(p.stat().st_size for p in export_files),
      len(export_files),len(export_dirs),sum(len(relative(bundle/'candidate',p).encode()) for p in export_entries),
      sum(files(bundle)),(bundle/'manifest.json').stat().st_size,(bundle/'record.json').stat().st_size,
      (bundle.parent.parent/'prepare.out').stat().st_size,
      max((candidate/'HEAD').stat().st_size,(candidate/'refs/heads/candidate').stat().st_size),
      max((candidate/'config').stat().st_size,len(subprocess.check_output([
          '/usr/bin/git','config','--file',str(candidate/'config'),'--no-includes','--null','--list']))),
      len(response_value['payloads'][0]['data'].encode()),
      len((json.dumps(response_value['stage_result'],ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode()),
      sum((repo/p['path']).stat().st_size for p in json.loads((bundle/'record.json').read_bytes())['producer']['core']['files'])+
      jq.stat().st_size,int(git('cat-file','-s',commit)),max(int(git('cat-file','-s',oid)) for oid in trees),
      sum(int(git('cat-file','-s',oid)) for oid in trees),len(trees),len(tree_rows),
      (reverse.stat().st_size-12-2*oid_bytes)//4)
PY
)
limit_pair input_bytes "$input_size" E_INPUT
limit_pair response_bytes "$response_size" E_INPUT
limit_pair storage_bytes "$storage_size"
limit_pair repository_file_bytes "$repository_file_size"
limit_pair reverse_index_bytes "$reverse_size"
limit_pair repository_entries "$repository_entries"
limit_pair repository_name_bytes "$repository_name_bytes"
limit_pair blob_bytes "$blob_size"
limit_pair export_bytes "$export_size"
limit_pair file_paths "$file_paths"
limit_pair directories "$directory_count"
limit_pair export_path_bytes "$export_path_bytes"
limit_pair bundle_bytes "$bundle_size"
limit_pair manifest_bytes "$manifest_size"
limit_pair record_bytes "$record_size"
limit_pair result_bytes "$result_size"
limit_pair head_ref_bytes "$head_size" E_INPUT
limit_pair config_bytes "$config_size" E_LIMIT
limit_pair receipt_bytes "$receipt_size" E_INPUT
limit_pair stage_result_bytes "$stage_size"
limit_pair dependency_bytes "$dependency_size"
limit_pair commit_bytes "$commit_size"
limit_pair tree_bytes "$tree_size"
limit_pair tree_bytes_visited "$tree_bytes"
limit_pair tree_visits "$tree_visits"
limit_pair tree_entries "$tree_entries"
limit_pair reverse_index_objects "$reverse_objects"

printf '1..%s\n' "$passed"
