#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  local scope_code=${1:-} scope_input=${1:-} scope_record='' scope_code_valid=true
  local scope_owner=F scope_point=${BASH_LINENO[0]:-0} scope_errno=UNKNOWN scope_rest
  if [ "${scope_reader_error:-false}" = true ]; then
    scope_code=${scope_input%%$'\n'*}
  fi
  case "$scope_code" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE) ;;
    *) scope_code=E_RUNTIME; scope_code_valid=false ;;
  esac
  /usr/bin/printf '%s\n' "$scope_code" >&2 || exit 1
  case "$scope_point" in
    ''|0*|*[!0-9]*) scope_owner=U; scope_point=0 ;;
    *) if [ "${#scope_point}" -gt 6 ]; then scope_owner=U; scope_point=0; fi ;;
  esac
  if [ "$scope_code_valid" = true ] && [ "${scope_reader_error:-false}" = true ] && [ "$scope_input" != "${scope_input#*$'\n'}" ]; then
    scope_record=${scope_input#*$'\n'}
    case "$scope_record" in
      'SCOPE_FAIL_V1 '*)
        scope_rest=${scope_record#SCOPE_FAIL_V1 }
        local candidate_owner=${scope_rest%% *}
        scope_rest=${scope_rest#* }
        local candidate_point=${scope_rest%% *} candidate_errno=${scope_rest#* }
        local scope_valid=true
        [ "$scope_record" = "SCOPE_FAIL_V1 $candidate_owner $candidate_point $candidate_errno" ] || scope_valid=false
        case "$candidate_owner:$candidate_point" in
          U:0) ;;
          F:*|R:*|C:*)
            case "$candidate_point" in ''|0*|*[!0-9]*) scope_valid=false ;; esac
            [ "${#candidate_point}" -le 6 ] || scope_valid=false ;;
          *) scope_valid=false ;;
        esac
        case "$candidate_errno" in
          NONE|EACCES|EPERM|ENOENT|ENOTDIR|EEXIST|ELOOP|EBADF|EMFILE|ENFILE|ENOSPC|EIO|EPIPE|EINTR|EINVAL|ETIMEDOUT|OTHER|UNKNOWN) ;;
          *) scope_valid=false ;;
        esac
        [ "${#scope_record}" -lt 64 ] || scope_valid=false
        if [ "$scope_valid" = true ]; then
          scope_owner=$candidate_owner; scope_point=$candidate_point; scope_errno=$candidate_errno
        fi ;;
    esac
  fi
  printf 'SCOPE_FAIL_V1 %s %s %s\n' "$scope_owner" "$scope_point" "$scope_errno" >&2 || :
  exit 1
}

sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

[ "$#" -eq 10 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
documents=("$1" "$2" "$3" "$4" "$5" "$6" "$7")
bundle_root=$8
source_git=$9
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-scope.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/scope/v1" ] || emit_error E_RUNTIME
policy="$source_dir/scope-policy.json"
record_program="$source_dir/workflow-scope.jq"
program="$source_dir/scope-gates.jq"
mode_marker="$repo/config/construction-mode.json"
for required in "$source_path" "$policy" "$record_program" "$program"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
for input in "${documents[@]}"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
done
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-scope-evaluate.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
reader_started=$SECONDS
/bin/mkdir -m 700 "$scratch/observation" || emit_error E_RUNTIME
reader_pid=''
control_open=false
control_verified=false
finish_reader() {
  if [ "$control_open" = true ]; then
    if [ "$control_verified" = true ]; then /usr/bin/printf 'CANCEL\n' >&7 || :; fi
    exec 7>&-
    control_open=false
  fi
  if [ -n "$reader_pid" ]; then
    wait "$reader_pid" 2>/dev/null || :
    reader_pid=''
  fi
}
remaining_time() {
  local remaining=$((300 - SECONDS + reader_started))
  if [ -n "${YSTACK_GATE_DEADLINE:-}" ]; then
    local inherited
    inherited=$("$python_bin" -I -S -B -c 'import math,sys,time; print(math.floor(float(sys.argv[1])-time.monotonic()))' "$YSTACK_GATE_DEADLINE") || emit_error E_RUNTIME
    case "$inherited" in ''|*[!0-9]*) emit_error E_RUNTIME ;; esac
    [ "$inherited" -ge "$remaining" ] || remaining=$inherited
  fi
  [ "$remaining" -gt 0 ] || emit_error E_RUNTIME
  /usr/bin/printf '%s' "$remaining"
}
cleanup() { finish_reader; exec 8<&-; /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; /usr/bin/printf '%s\n' E_RUNTIME >&2; printf 'SCOPE_FAIL_V1 U 0 UNKNOWN\n' >&2 || :; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

snapshot() {
  local source=$1 target=$2 size bom
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
  bom=$(/usr/bin/od -An -tx1 -N3 "$target" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" -e 'type == "object"' "$target" >/dev/null 2>&1 || emit_error E_PARSE
  [ "$("$jq_bin" -s 'length' "$target" 2>/dev/null)" = 1 ] || emit_error E_PARSE
}
canonicalize() {
  "$jq_bin" -S -c . "$1" >"$2" 2>/dev/null || emit_error E_PARSE
}
require_canonical() {
  canonicalize "$1" "$1.canonical"
  /usr/bin/cmp -s "$1" "$1.canonical" || emit_error E_CANONICAL
}

names=(scope shadow-set dashboard risk kill duty marker)
index=0
for input in "${documents[@]}"; do
  snapshot "$input" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for canonical in scope shadow-set dashboard risk kill duty marker; do
  require_canonical "$scratch/$canonical.json"
done
snapshot "$policy" "$scratch/policy.json"
require_canonical "$scratch/policy.json"

record_result=$("$jq_bin" -r -f "$record_program" "$scratch/scope.json" 2>/dev/null) ||
  emit_error E_RUNTIME
case "$record_result" in
  '') ;;
  E_SHAPE|E_RELATION) emit_error "$record_result" ;;
  *) emit_error E_RUNTIME ;;
esac

"$jq_bin" -e '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "scope_qualification_policy" and
  .id == "scope-policy.qualification" and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.fail_mode == "closed" and .body.policy_version == "v1" and
  .body.proposable_risk_tiers == ["routine"] and
  .body.required_eval_seed_status == "seeded" and
  .body.accepted_shadow_outcomes == ["no-change","reproduced"] and
  .body.refused_shadow_outcomes == ["inconclusive"] and
  .body.outcomes == ["not-proposable","proposable"] and
  (.body.protected_path_prefixes | length >= 1) and
  (.body.protected_root_files | length >= 1) and
  (.body.protected_path_segments | length >= 1)
' "$scratch/policy.json" >/dev/null 2>&1 || emit_error E_RELATION

# The operating-mode marker is read from the repository read-only and only ever
# compared. A supplied marker that disagrees with the committed one leaves the
# mode unknown, and the evaluator refuses rather than guessing. The supplied
# marker must already be canonical, so the committed one is put into canonical
# form in the scratch directory before the byte comparison: two markers are the
# same marker when their canonical bytes agree. The committed file is only read.
mode_repo_state=absent
committed_marker_sha=''
# A committed marker that exists as anything but a regular file (a symlink, a
# directory, a device) is not "absent": it is a tree this evaluator cannot read
# the mode from, and it refuses rather than letting a supplied marker decide.
if [ -e "$mode_marker" ] || [ -L "$mode_marker" ]; then
  [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ] || emit_error E_RUNTIME
fi
if [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ]; then
  snapshot "$mode_marker" "$scratch/repo-marker.json"
  committed_marker_sha=$(sha256_path "$scratch/repo-marker.json") ||
    emit_error E_RUNTIME
  canonicalize "$scratch/repo-marker.json" "$scratch/repo-marker-canonical.json"
  if /usr/bin/cmp -s "$scratch/marker.json" "$scratch/repo-marker-canonical.json"; then
    mode_repo_state=matched
  else
    mode_repo_state=differs
  fi
fi

record_count=$("$jq_bin" -r '
  if (.body | type) == "object" and (.body.records | type) == "array"
  then (.body.records | length) else 0 end
' "$scratch/shadow-set.json" 2>/dev/null) || emit_error E_RUNTIME
case "$record_count" in ''|*[!0-9]*) emit_error E_RUNTIME ;; esac
[ "$record_count" -le 16 ] || record_count=0
: >"$scratch/record-shas.txt"
record_index=0
while [ "$record_index" -lt "$record_count" ]; do
  "$jq_bin" -S -c --argjson i "$record_index" '.body.records[$i]' \
    "$scratch/shadow-set.json" >"$scratch/record.json" 2>/dev/null ||
    emit_error E_RUNTIME
  sha256_path "$scratch/record.json" >>"$scratch/record-shas.txt" ||
    emit_error E_RUNTIME
  record_index=$((record_index + 1))
done
record_shas=$("$jq_bin" -R -s -c 'split("\n") | map(select(length > 0))' \
  <"$scratch/record-shas.txt") || emit_error E_RUNTIME

reader="$source_dir/read-shadow-evidence.py"
[ -f "$reader" ] && [ ! -L "$reader" ] || emit_error E_RUNTIME
python_bin=$(command -v python3 2>/dev/null) || emit_error E_RUNTIME
python_bin=$("$python_bin" -I -S -B -c 'import os,sys;print(os.path.realpath(sys.executable))' 2>/dev/null) || emit_error E_RUNTIME
case "$python_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
reader_sha=$(sha256_path "$reader") || emit_error E_RUNTIME
consumer_sha=$(sha256_path "$repo/shadow/v1/_consumer.py") || emit_error E_RUNTIME
coverage_normalizer_sha=$(sha256_path "$repo/sandbox/v1/coverage-source.py") || emit_error E_RUNTIME
python_sha=$(sha256_path "$python_bin") || emit_error E_RUNTIME
jq_sha=$(sha256_path "$jq_bin") || emit_error E_RUNTIME
locator_snapshot() {
  /usr/bin/perl -e 'alarm shift; exec @ARGV; die "exec failed: $!\n"' \
    "$(remaining_time)" "$python_bin" -I -S -B - "$bundle_root" "$source_git" <<'PY_LOCATORS'
import hashlib,json,os,stat,sys
def identity(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,
            value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
digest=hashlib.sha256()
def retain(path, state):
    digest.update(json.dumps((path,identity(state)),separators=(',',':')).encode()+b'\n')
def walk(fd, path):
    before=os.fstat(fd);names=sorted(os.listdir(fd))
    retain(path,before)
    for name in names:
        value=os.stat(name,dir_fd=fd,follow_symlinks=False)
        if stat.S_ISDIR(value.st_mode):
            child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            try:
                if identity(os.fstat(child))!=identity(value):raise ValueError("E_STALE")
                walk(child,path+"/"+name)
                if identity(os.stat(name,dir_fd=fd,follow_symlinks=False))!=identity(value):
                    raise ValueError("E_STALE")
            finally:os.close(child)
        elif stat.S_ISREG(value.st_mode):retain(path+"/"+name,value)
        else:raise ValueError("E_RELATION")
    if identity(os.fstat(fd))!=identity(before) or sorted(os.listdir(fd))!=names:
        raise ValueError("E_STALE")
try:
    for path in sys.argv[1:]:
        if not os.path.isabs(path) or os.path.realpath(path)!=path:raise ValueError("E_RELATION")
        fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:walk(fd,path)
        finally:os.close(fd)
    print(digest.hexdigest())
except (OSError,ValueError) as error:
    print(str(error) if str(error) in {"E_LIMIT","E_STALE","E_RELATION"} else "E_RUNTIME",file=sys.stderr)
    raise SystemExit(1)
PY_LOCATORS
}
locator_before=$(locator_snapshot 2>"$scratch/locator-error") ||
  emit_error "$(/bin/cat "$scratch/locator-error")"
/usr/bin/mkfifo -m 600 "$scratch/reader-control" "$scratch/reader-ready" || emit_error E_RUNTIME
/bin/mkdir -m 700 "$scratch/reader-captures" "$scratch/reader-runtime" "$scratch/reader-runtime/no-hooks" || emit_error E_RUNTIME
exec 7<>"$scratch/reader-control"
exec 8<>"$scratch/reader-ready"
control_open=true
/usr/bin/perl -MFcntl=F_GETFL,F_SETFL,O_NONBLOCK -e '
  my $flags = fcntl(STDIN, F_GETFL, 0);
  defined($flags) && fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK) or exit 1;
' <&7 || emit_error E_RUNTIME
for prepared in observation.json observation.json.canonical evaluation.json evaluation.json.canonical reader-stderr \
  terminal.json terminal.json.canonical final-observation.json final-observation.json.canonical locator-error terminal-error; do
  : >"$scratch/$prepared" || emit_error E_RUNTIME
done
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C YSTACK_SCOPE_JQ="$jq_bin" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV; die "exec failed: $!\n"' "$(remaining_time)" "$python_bin" -I -S -B "$reader" read \
  "$scratch/scope.json" "$scratch/shadow-set.json" "$bundle_root" "$source_git" \
  "$scratch/observation/result.json" <&7 >&8 2>"$scratch/reader-stderr" 7>&- 8>&- &
reader_pid=$!
exec 9<"$scratch/reader-ready"
exec 8<&9
exec 9<&-
ready=$(/usr/bin/perl -e 'alarm shift; my $count=sysread(STDIN,my $frame,7);
  defined($count) && $frame eq "READY\n" or exit 1; print $frame or exit 1;
' "$(remaining_time)" <&8) || {
  finish_reader
  reader_error=$(/bin/cat "$scratch/reader-stderr") || emit_error E_RUNTIME
  scope_reader_error=true
  emit_error "$reader_error"
}
[ "$ready" = READY ] || emit_error E_RUNTIME
control_verified=true
snapshot "$scratch/observation/result.json" "$scratch/observation.json"
require_canonical "$scratch/observation.json"
observation_sha=$(sha256_path "$scratch/observation.json") || emit_error E_RUNTIME

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
scope_sha=$(sha256_path "$scratch/scope.json") || emit_error E_RUNTIME
shadow_set_sha=$(sha256_path "$scratch/shadow-set.json") || emit_error E_RUNTIME
dashboard_sha=$(sha256_path "$scratch/dashboard.json") || emit_error E_RUNTIME
dashboard_evaluator_sha=''
"$jq_bin" -S -c '
  if (.body | type) == "object" then
    if (.body.evaluator | type) == "object" then
      if (.body.evaluator.content | type) == "object" then .body.evaluator.content
      else empty end
    else empty end
  else empty end
' "$scratch/dashboard.json" >"$scratch/dashboard-evaluator.json" 2>/dev/null || emit_error E_RUNTIME
if [ -s "$scratch/dashboard-evaluator.json" ]; then
  dashboard_evaluator_sha=$(sha256_path "$scratch/dashboard-evaluator.json") || emit_error E_RUNTIME
fi
risk_sha=$(sha256_path "$scratch/risk.json") || emit_error E_RUNTIME
kill_sha=$(sha256_path "$scratch/kill.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty.json") || emit_error E_RUNTIME
marker_sha=$(sha256_path "$scratch/marker.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$program") || emit_error E_RUNTIME
record_program_sha=$(sha256_path "$record_program") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME

"$jq_bin" -S -c -n -f "$program" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile scope "$scratch/scope.json" \
  --slurpfile shadow_set "$scratch/shadow-set.json" \
  --slurpfile dashboard "$scratch/dashboard.json" \
  --slurpfile risk "$scratch/risk.json" \
  --slurpfile kill "$scratch/kill.json" \
  --slurpfile duty "$scratch/duty.json" \
  --slurpfile marker "$scratch/marker.json" \
  --slurpfile measured "$scratch/observation.json" \
  --argjson record_shas "$record_shas" \
  --arg mode_repo_state "$mode_repo_state" \
  --arg policy_sha "$policy_sha" --arg scope_sha "$scope_sha" \
  --arg shadow_set_sha "$shadow_set_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg dashboard_evaluator_sha "$dashboard_evaluator_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" \
  --arg duty_sha "$duty_sha" --arg marker_sha "$marker_sha" \
  >"$scratch/evaluation.json" 2>/dev/null || emit_error E_RUNTIME

[ "$(sha256_path "$repo/sandbox/v1/coverage-source.py")" = "$coverage_normalizer_sha" ] &&
[ "$(sha256_path "$reader")" = "$reader_sha" ] &&
  [ "$(sha256_path "$repo/shadow/v1/_consumer.py")" = "$consumer_sha" ] &&
  [ "$(sha256_path "$python_bin")" = "$python_sha" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  /usr/bin/cmp -s "$scratch/observation.json" "$scratch/observation/result.json" &&
  [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$record_program")" = "$record_program_sha" ] &&
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] || emit_error E_RELATION
index=0
for input in "${documents[@]}"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_STALE
  /usr/bin/cmp -s "$input" "$scratch/${names[$index]}.json" || emit_error E_STALE
  index=$((index + 1))
done
# The committed marker is an input to the result too: the snapshot above decided
# both the operating mode and the `repository_marker` field, so marker bytes
# that changed during the run would leave the evaluation describing a marker the
# repository no longer holds. It is rechecked here like every other input, and a
# marker that appeared, vanished, or changed makes the run stale.
if [ -n "$committed_marker_sha" ]; then
  [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ] &&
    [ "$(sha256_path "$mode_marker")" = "$committed_marker_sha" ] ||
    emit_error E_STALE
elif [ -e "$mode_marker" ] || [ -L "$mode_marker" ]; then
  # Anything that appeared at the marker path mid-run, regular or not, means
  # the repository's mode is no longer what this run read.
  emit_error E_STALE
fi
require_canonical "$scratch/evaluation.json"

"$jq_bin" -e --arg scope_id "$(
  "$jq_bin" -r '.id' "$scratch/scope.json")" --arg scope_sha "$scope_sha" '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "scope_qualification_evaluation" and
  .id == $scope_id and
  (.body | keys | sort) == ["activation_state","authority","authority_effect",
    "enabled","evaluation_mode","evidence","operating_mode","outcome","proposal",
    "qualification","reason_ids","reference_semantics","scope_ref"] and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.authority_effect == "none" and .body.enabled == false and
  .body.evaluation_mode == "observation-only" and
  .body.reference_semantics == "identity-only" and
  .body.qualification.state == "unavailable" and
  .body.scope_ref.sha256 == $scope_sha and
  (.body.outcome as $outcome |
   ["not-proposable","proposable"] | index($outcome) != null) and
  (.body.reason_ids |
   type == "array" and length >= 1 and all(.[]; type == "string") and
   . == (sort | unique)) and
  (if .body.outcome == "proposable"
   then .body.reason_ids == ["scope.proposable"] and
        .body.proposal.state == "present" and
        .body.proposal.document.kind == "scope_enablement_proposal" and
        .body.proposal.document.body.enabled == false and
        .body.proposal.document.body.push_allowed == false and
        .body.proposal.document.body.risk_tier == "routine" and
        .body.proposal.document.body.authority == "none" and
        .body.proposal.document.body.enablement.state == "blocked" and
        .body.proposal.document.body.qualification.state == "unavailable"
   else (.body.reason_ids | index("scope.proposable")) == null and
        .body.proposal == {state: "absent"} end) and
  ((.body | has("grant_ref") or has("activation") or has("qualification_ref")) | not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

/usr/bin/printf 'SEAL\n' >&7 || emit_error E_RUNTIME
exec 7>&-
control_open=false
commit=$(/usr/bin/perl -e 'alarm shift; my $count=sysread(STDIN,my $frame,97);
  defined($count) && length($frame)<=96 &&
  $frame =~ /\ACOMMIT ([1-9][0-9]{0,6}) ([0-9a-f]{64})\n\z/ && $1<=1048576 or exit 1;
  print $frame or exit 1;
' "$(remaining_time)" <&8) || emit_error E_RUNTIME
commit_values=${commit#COMMIT }
commit_size=${commit_values%% *}
commit_sha=${commit_values#* }
reader_status=0
wait "$reader_pid" || reader_status=$?
reader_pid=''
[ "$(/usr/bin/wc -c <"$scratch/reader-stderr" | /usr/bin/tr -d ' ')" -le 65536 ] || emit_error E_LIMIT
if [ "$reader_status" -ne 0 ]; then
  reader_error=$(/bin/cat "$scratch/reader-stderr") || emit_error E_RUNTIME
  scope_reader_error=true
  emit_error "$reader_error"
fi
[ ! -s "$scratch/reader-stderr" ] || emit_error E_RUNTIME
/usr/bin/perl -e 'alarm shift; my $count=sysread(STDIN,my $byte,1);
  defined($count) && $count==0 or exit 1;
' "$(remaining_time)" <&8 || emit_error E_RUNTIME
exec 8<&-

terminal_status=0
/usr/bin/perl -e 'alarm shift; exec @ARGV; die "exec failed: $!\n"' \
  "$(remaining_time)" "$python_bin" -I -S -B - \
  "$scratch/observation" "$scratch/terminal.json" "$commit_size" "$commit_sha" \
  2>"$scratch/terminal-error" <<'PY_TERMINAL_SNAPSHOT' || terminal_status=$?
import hashlib,os,stat,sys
parent=source=target=None
class SnapshotRefusal(Exception):pass
def require_snapshot(value,code):
    if not value:raise SnapshotRefusal(code)
def identity(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_gid,
            value.st_nlink,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
try:
    directory,destination,maximum,commit_sha=sys.argv[1:];maximum=int(maximum)
    parent=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    before=os.stat("terminal.json",dir_fd=parent,follow_symlinks=False)
    require_snapshot(stat.S_ISREG(before.st_mode) and before.st_nlink==1,"E_RUNTIME")
    source=os.open("terminal.json",os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW,dir_fd=parent)
    require_snapshot(identity(os.fstat(source))==identity(before),"E_STALE")
    chunks=[];received=0
    while received<maximum+1:
        raw=os.read(source,min(65536,maximum+1-received))
        if not raw:break
        chunks.append(raw);received+=len(raw)
    require_snapshot(identity(os.fstat(source))==identity(before) and
        identity(os.stat("terminal.json",dir_fd=parent,follow_symlinks=False))==identity(before),"E_STALE")
    raw=b"".join(chunks)
    require_snapshot(hashlib.sha256(raw).hexdigest()==commit_sha,"E_RELATION")
    require_snapshot(received==maximum and before.st_size==maximum,"E_RELATION")
    named=os.lstat(destination)
    require_snapshot(stat.S_ISREG(named.st_mode) and named.st_nlink==1,"E_RUNTIME")
    target=os.open(destination,os.O_WRONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
    require_snapshot(identity(os.fstat(target))==identity(named),"E_STALE")
    os.ftruncate(target,0)
    for raw in chunks:
        sent=0
        while sent<len(raw):
            count=os.write(target,raw[sent:])
            if count<=0:raise OSError("snapshot write failed")
            sent+=count
except SnapshotRefusal as error:
    print(str(error),file=sys.stderr);raise SystemExit(1)
except BaseException as error:
    print("E_RUNTIME",file=sys.stderr);print(repr(error),file=sys.stderr);raise SystemExit(1)
finally:
    for descriptor in (target,source,parent):
        if descriptor is not None:os.close(descriptor)
PY_TERMINAL_SNAPSHOT
[ "$(/usr/bin/wc -c <"$scratch/terminal-error" | /usr/bin/tr -d ' ')" -le 65536 ] || emit_error E_RUNTIME
if [ "$terminal_status" -ne 0 ]; then
  terminal_error=$(/bin/dd if="$scratch/terminal-error" bs=65537 count=1 2>/dev/null) || emit_error E_RUNTIME
  /usr/bin/printf '%s\n' "$terminal_error" | /usr/bin/cmp -s - "$scratch/terminal-error" || emit_error E_RUNTIME
  case "$terminal_error" in E_RELATION|E_STALE|E_RUNTIME) emit_error "$terminal_error" ;; *) emit_error E_RUNTIME ;; esac
fi
[ ! -s "$scratch/terminal-error" ] || emit_error E_RUNTIME
[ "$(sha256_path "$scratch/terminal.json")" = "$commit_sha" ] || emit_error E_RELATION
require_canonical "$scratch/terminal.json"
"$jq_bin" -e --slurpfile original "$scratch/observation.json" --arg original_sha "$observation_sha" '
  (keys | sort) == ["body","id","kind","schema_version"] and
  (.schema_version | type == "number") and .schema_version == 1 and
  .kind == "scope_shadow_evidence_terminal" and .id == $original[0].id and
  (.body | keys == ["commands","observation_sha256"]) and
  .body.observation_sha256 == $original_sha and
  (.body.commands | type == "array" and length <= 4096 and
    all(.[]; (if .role == "coverage-source-boundary" then
        keys == ["argv_sha256","component_sha256","executable_sha256","python_sha256","request_sha256","role"] and
        all(.request_sha256,.python_sha256; type == "string" and test("\\A[0-9a-f]{64}\\z"))
      else keys == ["argv_sha256","component_sha256","executable_sha256","role"] end) and
      (.role | type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
      all(.argv_sha256,.component_sha256,.executable_sha256;
        type == "string" and test("\\A[0-9a-f]{64}\\z")))) and
  .body.commands[0:($original[0].body.commands | length)] == $original[0].body.commands
' "$scratch/terminal.json" >/dev/null 2>&1 || emit_error E_RELATION
"$jq_bin" -S -c --slurpfile terminal "$scratch/terminal.json" \
  '.body.commands=$terminal[0].body.commands' "$scratch/observation.json" \
  >"$scratch/final-observation.json" || emit_error E_RUNTIME
"$jq_bin" -e --slurpfile original "$scratch/observation.json" \
  'del(.body.commands) == ($original[0] | del(.body.commands))' \
  "$scratch/final-observation.json" >/dev/null || emit_error E_RELATION
require_canonical "$scratch/final-observation.json"
[ "$(sha256_path "$scratch/observation.json")" = "$observation_sha" ] &&
  [ "$(sha256_path "$scratch/terminal.json")" = "$commit_sha" ] || emit_error E_STALE
/usr/bin/cmp -s "$scratch/observation/terminal.json" "$scratch/terminal.json" || emit_error E_STALE
[ "$(locator_snapshot 2>"$scratch/locator-error")" = "$locator_before" ] || emit_error E_STALE
for required in "$source_path" "$policy" "$record_program" "$program" "$reader" "$repo/shadow/v1/_consumer.py" "$repo/sandbox/v1/coverage-source.py" "$python_bin" "$jq_bin"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_STALE
done
[ "$(sha256_path "$source_path")" = "$driver_sha" ] &&
  [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
  [ "$(sha256_path "$record_program")" = "$record_program_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$repo/sandbox/v1/coverage-source.py")" = "$coverage_normalizer_sha" ] &&
[ "$(sha256_path "$reader")" = "$reader_sha" ] &&
  [ "$(sha256_path "$repo/shadow/v1/_consumer.py")" = "$consumer_sha" ] &&
  [ "$(sha256_path "$python_bin")" = "$python_sha" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_STALE
index=0
for input in "${documents[@]}"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_STALE
  /usr/bin/cmp -s "$input" "$scratch/${names[$index]}.json" || emit_error E_STALE
  index=$((index+1))
done

/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
