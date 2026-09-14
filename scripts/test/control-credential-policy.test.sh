#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_CREDENTIAL_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_CREDENTIAL_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 180; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-credential-policy.sh"
duty_evaluator="$root/control/v1/evaluate-duty.sh"
policy="$root/control/v1/credential-policy.json"
decision="$root/control/v1/credential-policy-decision.json"
program="$root/control/v1/credential-policy.jq"
duty_policy="$root/control/v1/duty-separation-policy.json"
duty_decision="$root/control/v1/duty-separation-decision.json"
core_wrapper="$root/scripts/core-contract.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-credential-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
INPUT_RACE_PID=
INPUT_RACE_PGID=
INPUT_RACE_STATUS=
STOPPED_MARKER_PATH=
SETUP_CONTEXT=0
SETUP_OPERATION=none
SETUP_LIFECYCLE=empty
SETUP_OUTCOME=
SETUP_SIGNAL=
WAIT_INTERRUPTED=0
WAIT_STATUS=0
LOCAL_REAP_ACTIVE=0
LOCAL_REAP_PID=
PROBE_RESULT=error
SIGNAL_CHILD_PID=
SIGNAL_CHILD_PGID=
SIGNAL_DESCENDANT_PID=
CONTROL_CONTEXT=0
CONTROL_PHASE=inactive
CONTROL_FAILURE=
CONTROL_SIGNAL=
CONTROL_JOB=
CONTROL_JOB_ACQUIRED=0
CONTROL_WAIT_ACTIVE=0
CONTROL_WAIT_INTERRUPTED=0
CONTROL_WAIT_STATUS=
CONTROL_WAIT_STATUS_STATE=unconfirmed
CONTROL_POSSIBLY_RELEASED=0
CONTROL_RETAIN_SCRATCH=0
CONTROL_GATE_OPEN=0
CONTROL_GATE_PATH=
CONTROL_CASE_PATH=
CONTROL_IDENTITY_PATH=
CONTROL_MONITOR_WAS=off
TEST_PGID=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ') || exit 1
[[ "$TEST_PGID" =~ ^[1-9][0-9]*$ ]] || exit 1
group_alive() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$1" 2>/dev/null
}
# Test-private lifecycle boundary; work/credential-test-synchronization/spec.md R2a.
managed_enter() { SETUP_CONTEXT=1; }
managed_operation() { SETUP_OPERATION=$1; }
managed_lifecycle() { SETUP_LIFECYCLE=$1; }
managed_outcome() { SETUP_OUTCOME=$1; }
managed_release() { SETUP_CONTEXT=0; }
managed_kill() { /bin/kill "$@"; }
managed_wait() {
  WAIT_STATUS=0
  builtin wait "$1" 2>/dev/null || WAIT_STATUS=$?
}
managed_reap() {
  local child=$1 mode=$2
  if [ "$mode" = local ]; then
    [ "$LOCAL_REAP_ACTIVE" -eq 1 ] && [ "$LOCAL_REAP_PID" = "$child" ] || return 1
  fi
  while :; do
    WAIT_INTERRUPTED=0
    managed_wait "$child"
    [ "$WAIT_INTERRUPTED" -eq 0 ] && break
  done
  if [ "$mode" = local ]; then
    LOCAL_REAP_ACTIVE=0
  else
    managed_lifecycle retired-unconfirmed
  fi
  [ "$WAIT_STATUS" -ne 127 ]
}
managed_probe_command() {
  /usr/bin/perl -MErrno=ESRCH -e '
    my $n = kill 0, -$ARGV[0];
    print $n ? "alive" : ($! == ESRCH ? "absent" : "error");
  ' "$1"
}
managed_probe() {
  local value status=0
  value=$(managed_probe_command "$1" 2>/dev/null) || status=$?
  PROBE_RESULT=error
  if [ "$status" -eq 0 ]; then
    case "$value" in alive|absent|error) PROBE_RESULT=$value ;; esac
  fi
}

managed_pending() {
  [ -z "$SETUP_SIGNAL" ] || managed_dispatch "$SETUP_SIGNAL"
}
managed_end_operation() {
  managed_operation none
  managed_pending
}
managed_terminate() {
  local status=0
  managed_operation terminating
  terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || status=$?
  managed_end_operation
  [ "$status" -eq 0 ] || fail 'setup cleanup unconfirmed'
}
managed_dispatch() {
  local cause=$1 status=1
  if [ "$CONTROL_CONTEXT" -eq 1 ]; then
    if [ "$cause" != EXIT ]; then
      [ -n "$CONTROL_SIGNAL" ] || CONTROL_SIGNAL=$cause
      [ -n "$CONTROL_FAILURE" ] || CONTROL_FAILURE=signal
      if [ "$CONTROL_WAIT_ACTIVE" -eq 1 ]; then
        CONTROL_WAIT_INTERRUPTED=1
      fi
      return
    fi
    CONTROL_RETAIN_SCRATCH=1
    cleanup
    return
  fi
  if [ "$SETUP_CONTEXT" -eq 0 ]; then
    cleanup
    return
  fi
  if [ "$cause" != EXIT ]; then
    [ -n "$SETUP_SIGNAL" ] || SETUP_SIGNAL=$cause
    case "$SETUP_OPERATION" in
      launching|observing|terminating)
        if [ "$SETUP_LIFECYCLE" = wait-in-progress ] ||
           [ "$LOCAL_REAP_ACTIVE" -eq 1 ]; then WAIT_INTERRUPTED=1; fi
        return ;;
    esac
  fi
  if [ "$SETUP_LIFECYCLE" = owned-live ] &&
     [ "$SETUP_OPERATION" != terminating ]; then
    managed_operation terminating
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" ||
      /usr/bin/printf '%s\n' 'setup cleanup unconfirmed' >&2
  fi
  trap - EXIT HUP INT TERM
  case "$SETUP_SIGNAL" in HUP) status=129 ;; INT) status=130 ;; TERM) status=143 ;; esac
  /usr/bin/printf 'setup terminal: %s\n' "$cause" >&2
  cleanup
  exit "$status"
}
managed_clear_attempt() {
  INPUT_RACE_PID=
  INPUT_RACE_PGID=
  STOPPED_MARKER_PATH=
  SETUP_OUTCOME=
  managed_lifecycle empty
}
managed_inspect_scratch() {
  local entries
  entries=$(/usr/bin/find "$1" -mindepth 1 -print -quit) ||
    fail 'setup scratch inspection failed'
  [ -z "$entries" ] || fail 'setup scratch not empty'
}
managed_preserve_output() {
  /bin/mv "$INPUT_RACE_OUT" "$tmp/$1.attempt-$2.stdout" ||
    fail 'setup output preservation failed'
  /bin/mv "$INPUT_RACE_ERR" "$tmp/$1.attempt-$2.stderr" ||
    fail 'setup output preservation failed'
}
coordinate_input_setup() {
  local name=$1 scratch_root=$2 claim_path=$3 attempt=1
  [ "$SETUP_CONTEXT" -eq 0 ] && [ -z "$INPUT_RACE_PID" ] &&
    [ -z "$INPUT_RACE_PGID" ] || fail 'setup context entry'
  SETUP_OPERATION=none
  SETUP_LIFECYCLE=empty
  SETUP_OUTCOME=
  STOPPED_MARKER_PATH=
  managed_enter
  while [ "$attempt" -le 3 ]; do
    managed_pending
    managed_operation launching
    start_input_race "$name" "$scratch_root" "$claim_path"
    managed_end_operation
    managed_operation observing
    stop_at_owned_marker "$name" "$scratch_root" input-snapshot-pending \
      input-snapshot-ready setup-miss
    managed_end_operation
    case "$SETUP_OUTCOME" in
      stopped)
        managed_pending
        managed_release
        return ;;
      missed-window) ;;
      *) fail 'setup invalid observer outcome' ;;
    esac
    managed_terminate
    managed_inspect_scratch "$scratch_root"
    managed_preserve_output "$name" "$attempt"
    /usr/bin/printf 'setup-miss: %s attempt %s\n' "$name" "$attempt" >&2
    managed_clear_attempt
    [ "$attempt" -lt 3 ] || fail 'setup attempts exhausted'
    attempt=$((attempt + 1))
  done
}

terminate_input_race() {
  local leader=$1 group=$2 attempt=0 problem=0 reaped=0
  if [ "$SETUP_CONTEXT" -eq 1 ]; then
    if [[ ! "$leader" =~ ^[1-9][0-9]*$ ]] ||
       [[ ! "$group" =~ ^[1-9][0-9]*$ ]] ||
       [ "$leader" != "$group" ] || [ "$group" = "$TEST_PGID" ]; then
      managed_lifecycle rejected-before-signal
      return 1
    fi
    managed_kill -TERM -- "-$group" 2>/dev/null || problem=1
    managed_kill -CONT -- "-$group" 2>/dev/null || problem=1
    managed_probe "$group"
    [ "$PROBE_RESULT" != error ] || problem=1
    while [ "$PROBE_RESULT" != absent ] && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      /bin/sleep 0.01 || problem=1
      managed_probe "$group"
      [ "$PROBE_RESULT" != error ] || problem=1
    done
    if [ "$PROBE_RESULT" != absent ]; then
      managed_kill -KILL -- "-$group" 2>/dev/null || problem=1
      attempt=0
      managed_probe "$group"
      [ "$PROBE_RESULT" != error ] || problem=1
      while [ "$PROBE_RESULT" != absent ] && [ "$attempt" -lt 100 ]; do
        attempt=$((attempt + 1))
        /bin/sleep 0.01 || problem=1
        managed_probe "$group"
        [ "$PROBE_RESULT" != error ] || problem=1
      done
    fi
    managed_lifecycle wait-in-progress
    managed_reap "$leader" group || reaped=1
    managed_probe "$group"
    if [ "$problem" -eq 0 ] && [ "$reaped" -eq 0 ] &&
       [ "$PROBE_RESULT" = absent ]; then
      managed_lifecycle retired
      return 0
    fi
    return 1
  fi
  [[ "$leader" =~ ^[1-9][0-9]*$ ]] && [[ "$group" =~ ^[1-9][0-9]*$ ]] &&
    [ "$leader" = "$group" ] && [ "$group" != "$TEST_PGID" ] || return 1
  /bin/kill -TERM -- "-$group" 2>/dev/null || :
  /bin/kill -CONT -- "-$group" 2>/dev/null || :
  while group_alive "$group" && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  if group_alive "$group"; then
    /bin/kill -KILL -- "-$group" 2>/dev/null || :
    attempt=0
    while group_alive "$group" && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      /bin/sleep 0.01
    done
  fi
  wait "$leader" 2>/dev/null || :
  ! group_alive "$group"
}
cleanup() {
  if [ "$SETUP_CONTEXT" -eq 0 ] &&
     { [ -n "${INPUT_RACE_PID:-}" ] || [ -n "${INPUT_RACE_PGID:-}" ]; }; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
  fi
  if [ -n "${SIGNAL_CHILD_PID:-}" ] || [ -n "${SIGNAL_CHILD_PGID:-}" ]; then
    terminate_input_race "$SIGNAL_CHILD_PID" "$SIGNAL_CHILD_PGID" || :
  fi
  if [ "${CONTROL_RETAIN_SCRATCH:-0}" -eq 0 ]; then
    /bin/rm -rf -- "$tmp"
  else
    /usr/bin/printf 'credential-handoff-retained: %s\n' "$tmp" >&2
  fi
}
trap 'managed_dispatch EXIT' EXIT
trap 'managed_dispatch HUP' HUP
trap 'managed_dispatch INT' INT
trap 'managed_dispatch TERM' TERM
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*)
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 0700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core_wrapper") ||
  fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
duty_policy_sha=$(sha256_path "$duty_policy")
duty_decision_sha=$(sha256_path "$duty_decision")
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")

for canonical_source in "$policy" "$decision"; do
  "$jq_bin" -S -c . "$canonical_source" >"$tmp/canonical"
  /usr/bin/cmp -s "$canonical_source" "$tmp/canonical" ||
    fail "canonical ${canonical_source##*/}"
done
for source_path in control/v1/credential-policy.json \
  control/v1/credential-policy-decision.json control/v1/credential-policy.jq \
  control/v1/evaluate-credential-policy.sh \
  scripts/test/control-credential-policy.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation $source_path"
done
pass 'canonical definitions and opaque generation identity'

snapshot_fixed_exec_body=$(/usr/bin/awk '
  /^snapshot_fixed_executable\(\) \{/ {capture=1}
  capture {print}
  capture && /^}$/ {exit}
' "$evaluator")
mirror_builder=$(/usr/bin/awk '
  /^build_runtime_mirror\(\) \{/ {capture=1}
  capture {print}
  capture && /^}$/ {exit}
' "$evaluator")
snapshot_chmod_line=$(/usr/bin/printf '%s\n' "$snapshot_fixed_exec_body" |
  /usr/bin/awk '/\/bin\/chmod 0500/ {print NR}')
snapshot_pin_line=$(/usr/bin/printf '%s\n' "$snapshot_fixed_exec_body" |
  /usr/bin/awk '/pin_path "\$target" 1048576/ {print NR}')
snapshot_pin_count=$(/usr/bin/printf '%s\n' "$snapshot_fixed_exec_body" |
  /usr/bin/grep -Fc 'pin_path "$target" 1048576')
if [ -z "$snapshot_chmod_line" ] || [ -z "$snapshot_pin_line" ] ||
   [ "$snapshot_chmod_line" -ge "$snapshot_pin_line" ] ||
   [ "$snapshot_pin_count" -ne 1 ] ||
   ! /usr/bin/printf '%s\n' "$snapshot_fixed_exec_body" |
     /usr/bin/grep -Fq 'snapshot_nofollow "$source" "$target" 1048576'; then
  fail 'fixed executable final-mode pin order'
fi
for mirror_executable in control/v1/evaluate-duty.sh control/v1/validate.sh \
  scripts/core-contract.sh; do
  /usr/bin/printf '%s\n' "$mirror_builder" |
    /usr/bin/grep -Fq "$mirror_executable" ||
    fail "mirror executable missing $mirror_executable"
done
/usr/bin/printf '%s\n' "$mirror_builder" |
  /usr/bin/grep -Fq 'snapshot_fixed_executable "$source" "$target"' ||
  fail 'mirror executable snapshot path'
if /usr/bin/printf '%s\n' "$mirror_builder" | /usr/bin/grep -Fq '/bin/chmod'; then
  fail 'mirror builder mutates mode after snapshot pin'
fi
pass 'mirrored executables pin only after final mode'

final_success_body=$(/usr/bin/awk '
  /^output_text=\$\(capture_pinned_text/ {capture=1}
  capture {print}
' "$evaluator")
final_capture_line=$(/usr/bin/printf '%s\n' "$final_success_body" |
  /usr/bin/awk '/^output_text=\$\(capture_pinned_text/ {print NR; exit}')
final_cleanup_line=$(/usr/bin/printf '%s\n' "$final_success_body" |
  /usr/bin/awk '/^if ! cleanup/ {print NR; exit}')
final_disarm_line=$(/usr/bin/printf '%s\n' "$final_success_body" |
  /usr/bin/awk '/^trap - EXIT HUP INT TERM/ {print NR; exit}')
final_output_line=$(/usr/bin/printf '%s\n' "$final_success_body" |
  /usr/bin/awk '/^\/usr\/bin\/printf .*"\$output_text"/ {print NR; exit}')
if [ -z "$final_capture_line" ] || [ -z "$final_cleanup_line" ] ||
   [ -z "$final_disarm_line" ] || [ -z "$final_output_line" ] ||
   [ "$final_capture_line" -ge "$final_cleanup_line" ] ||
   [ "$final_cleanup_line" -ge "$final_disarm_line" ] ||
   [ "$final_disarm_line" -ge "$final_output_line" ]; then
  fail 'success cleanup trap order'
fi
pass 'success keeps cleanup armed through deletion before output'

startup_trap_line=$(/usr/bin/awk '/^trap cleanup EXIT/ {print NR; exit}' "$evaluator")
startup_mktemp_line=$(/usr/bin/awk "/^scratch=\\\$\\(\\/usr\\/bin\\/mktemp/ {print NR; exit}" \
  "$evaluator")
if [ -z "$startup_trap_line" ] || [ -z "$startup_mktemp_line" ] ||
   [ "$startup_trap_line" -ge "$startup_mktemp_line" ]; then
  fail 'cleanup trap must precede scratch creation'
fi
pass 'cleanup is armed before scratch creation'

terminate_body=$(/usr/bin/awk '
  /^terminate_active\(\) \{/ {capture=1}
  capture {print}
  capture && /^}$/ {exit}
' "$evaluator")
terminate_wait_line=$(/usr/bin/printf '%s\n' "$terminate_body" |
  /usr/bin/awk '/wait "\$leader"/ {print NR; exit}')
terminate_clear_line=$(/usr/bin/printf '%s\n' "$terminate_body" |
  /usr/bin/awk '/ACTIVE_PID=/ {line=NR} END {print line}')
terminate_post_group_line=$(/usr/bin/printf '%s\n' "$terminate_body" |
  /usr/bin/awk '/group_live_count/ {line=NR} END {print line}')
if [ -z "$terminate_wait_line" ] || [ -z "$terminate_clear_line" ] ||
   [ -z "$terminate_post_group_line" ] ||
   [ "$terminate_wait_line" -ge "$terminate_post_group_line" ] ||
   [ "$terminate_post_group_line" -ge "$terminate_clear_line" ]; then
  fail 'owned leader reap must precede group clear'
fi
pass 'terminate reaps its owned leader before clearing the process group'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg credential_policy_sha "$policy_sha" \
  --arg credential_decision_sha "$decision_sha" \
  --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" --arg generation "$generation" \
  --arg core_package_sha "$core_package_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy_sha;$decision_sha):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;
       "application/vnd.ystack.control-policy+json";$policy_sha),
     decision_ref:ref("control-decision."+$id;
       "application/vnd.ystack.control-decision+json";$decision_sha)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.test",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
     core_contract:{semantic_identity:"core.contracts.v2",generation_id:$generation,
       package_ref:ref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";$core_package_sha)},
     sections:[section("credential-policy";$credential_policy_sha;$credential_decision_sha),
       section("duty-separation";$duty_policy_sha;$duty_decision_sha),
       section("evidence-integrity";("3"*64);("c"*64)),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";("5"*64);("e"*64)),
       section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set"
policy_set_sha=$(sha256_path "$policy_set")

resolved="$tmp/resolved.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  def forge_binding($sha):
    {binding_id:"binding.forge",role:"forge",
     manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$sha},
     execution_kind:"deterministic",adapter_instance_id:"instance.forge",
     principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
     authority_ref:profile::scope("authority";"authority-forge";profile::sha("5")),
     package_ref:profile::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
     requested_capabilities:["core.forge.materialize-candidate.v2"],
     requested_permissions:["core.perm.candidate-repository.write.v2",
       "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
       "core.perm.target.read.v1"]};
  {forge:("1"*64),producer:("2"*64),publisher:("3"*64),
   reviewer:("4"*64),verifier:("5"*64)} as $shas |
  (profile::profile_doc($shas) | v2 | .body.profile_version="v2" |
   .body.bindings += [forge_binding($shas.forge)] |
   .body.bindings |= sort_by(.binding_id)) as $profile |
  profile::resolved_profile_doc($profile;("0"*64);$shas) | v2 |
  .body.bindings |= map(if .binding.role == "forge" then
    .adapter_implementation.version="v2" |
    .manifest_source=profile::source_value(
      profile::blob("manifests/forge.json";"a");"canonical-json";$shas.forge)
    else . end)
' >"$resolved"
resolved_sha=$(sha256_path "$resolved")

request="$tmp/request.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("producer";$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$request"
request_sha=$(sha256_path "$request")
result="$tmp/result.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$request" --slurpfile resolved "$resolved" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$result"
result_sha=$(sha256_path "$result")
duty="$tmp/duty.json"
PATH="$bin:/usr/bin:/bin" "$duty_evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" >"$duty" 2>"$tmp/duty.err" || {
    /bin/cat "$tmp/duty.err" >&2
    fail 'build duty evaluation'
  }
duty_sha=$(sha256_path "$duty")

claim="$tmp/claim.json"
"$jq_bin" -S -c -n --slurpfile set "$policy_set" --slurpfile duty "$duty" \
  --slurpfile result "$result" --slurpfile resolved "$resolved" \
  --arg set_sha "$policy_set_sha" --arg duty_sha "$duty_sha" \
  --arg result_sha "$result_sha" '
  def doc($document;$sha):
    {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,sha256:$sha};
  def actor($entry):
    {role:$entry.binding.role,implementation_id:$entry.adapter_implementation.id,
     implementation_version:$entry.adapter_implementation.version,
     adapter_instance_id:$entry.binding.adapter_instance_id,
     principal_id:$entry.binding.principal_id,
     execution_boundary_id:$entry.binding.execution_boundary_id};
  {schema_version:1,kind:"credential_boundary_claim",id:"credential-claim.test",
   body:{accesses:[$resolved[0].body.bindings[] |
       {actor:actor(.),binding_id:.binding.binding_id,
        credentials:(if .binding.execution_kind=="model" and
          (.binding.role=="producer" or .binding.role=="reviewer")
          then [{credential_class:"model-inference",delivery:"brokered",
            exposure:"none",scope:"single-stage"}] else [] end)}] | sort_by(.binding_id),
     activation_state:"inactive",declaration_status:"complete",
     duty_evaluation_ref:doc($duty[0];$duty_sha),
     policy_set_ref:doc($set[0];$set_sha),
     stage_result_ref:doc($result[0];$result_sha)}}
' >"$claim"

run_driver() {
  local name=$1 claim_path=${2:-$claim} duty_path=${3:-$duty}
  local runtime=${4:-$root} run_status=0 out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-credential-policy.sh" \
    evaluate "$policy_set" "$request" "$resolved" "$result" "$duty_path" \
    "$claim_path" >"$out" 2>"$err" || run_status=$?
  [ "$run_status" -eq 0 ] && [ ! -s "$err" ] || {
    /bin/cat "$err" >&2
    fail "$name driver"
  }
}

run_pure() {
  local name=$1 claim_path=$2 expected=$3 reason=$4 duty_path=${5:-$duty}
  local pure_claim_sha pure_duty_sha
  pure_claim_sha=$(sha256_path "$claim_path")
  pure_duty_sha=$(sha256_path "$duty_path")
  "$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
    --slurpfile decision "$decision" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --slurpfile result "$result" --slurpfile duty "$duty_path" \
    --slurpfile claim "$claim_path" --arg policy_sha "$policy_sha" \
    --arg decision_sha "$decision_sha" --arg policy_set_sha "$policy_set_sha" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    --arg result_sha "$result_sha" --arg duty_sha "$pure_duty_sha" \
    --arg claim_sha "$pure_claim_sha" >"$tmp/$name.out" 2>"$tmp/$name.err" || {
      /bin/cat "$tmp/$name.err" >&2
      fail "$name pure status"
    }
  [ ! -s "$tmp/$name.err" ] || fail "$name pure stderr"
  "$jq_bin" -e --arg expected "$expected" --arg reason "$reason" '
    .body.verdict==$expected and (.body.reason_ids|index($reason)!=null) and
    .body.reason_ids==(.body.reason_ids|sort|unique) and
    .body.activation_state=="inactive" and .body.authority_effect=="none" and
    .body.qualification_effect=="none" and
    ((.body|has("grant_ref") or has("activation") or has("credential_ref"))|not)
  ' "$tmp/$name.out" >/dev/null || fail "$name pure verdict"
  pass "$name"
}

mutate_claim() {
  local name=$1 filter=$2 destination
  destination="$tmp/$name.claim"
  "$jq_bin" -S -c "$filter" "$claim" >"$destination"
  /usr/bin/printf '%s\n' "$destination"
}

managed_gate_remove() { /bin/rm -f -- "$1"; }
managed_launch_group() {
  LAUNCH_GROUP=$(/bin/ps -o pgid= -p "$1" 2>/dev/null |
    /usr/bin/tr -d ' ')
}

control_enter() {
  [ "$CONTROL_CONTEXT" -eq 0 ] && [ "$CONTROL_JOB_ACQUIRED" -eq 0 ] ||
    fail 'control context entry'
  CONTROL_CONTEXT=1
  CONTROL_PHASE=entered
  CONTROL_FAILURE=
  CONTROL_SIGNAL=
  CONTROL_JOB=
  CONTROL_JOB_ACQUIRED=0
  CONTROL_WAIT_ACTIVE=0
  CONTROL_WAIT_INTERRUPTED=0
  CONTROL_WAIT_STATUS=
  CONTROL_WAIT_STATUS_STATE=unconfirmed
  CONTROL_POSSIBLY_RELEASED=0
  CONTROL_RETAIN_SCRATCH=1
  CONTROL_GATE_OPEN=0
  CONTROL_GATE_PATH=
  CONTROL_CASE_PATH=
  CONTROL_IDENTITY_PATH=
  case $- in *m*) CONTROL_MONITOR_WAS=on ;; *) CONTROL_MONITOR_WAS=off ;; esac
}

control_phase() {
  case "$CONTROL_PHASE:$1" in
    entered:prepared|prepared:launched|launched:identified|identified:release-possible|\
    release-possible:wait-only|identified:wait-only|launched:wait-only|prepared:wait-only|\
    wait-only:retired|retired:inspected|inspected:complete) CONTROL_PHASE=$1 ;;
    *) return 1 ;;
  esac
}

control_record_failure() {
  [ -n "$CONTROL_FAILURE" ] || CONTROL_FAILURE=$1
}

control_pending() {
  [ -z "$CONTROL_SIGNAL" ] || {
    control_record_failure signal
    return 1
  }
}

control_identity_read() {
  PERL5LIB= PERLLIB= PERL5OPT= /usr/bin/perl -MFcntl=O_RDONLY,O_NONBLOCK,O_NOFOLLOW \
    -MPOSIX=S_ISREG -e '
      use strict;
      use warnings;
      my ($path) = @ARGV;
      sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW) or exit 2;
      my @stat = stat($fh);
      @stat && S_ISREG($stat[2]) or exit 3;
      my $text = "";
      while (length($text) < 65) {
        my $count = sysread($fh, my $part, 65 - length($text));
        defined($count) or exit 4;
        last if $count == 0;
        $text .= $part;
      }
      close($fh) or exit 5;
      length($text) <= 64 or exit 6;
      $text =~ /\A([1-9][0-9]*) ([1-9][0-9]*)\n\z/ or exit 7;
      print "$1 $2\n" or exit 8;
    ' "$1"
}

control_identity_present() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    return 0
  fi
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

control_launch_job() {
  /bin/bash "$1" "$2" "$3" "$4" >"$5" 2>"$6" &
  CONTROL_JOB=$!
  CONTROL_JOB_ACQUIRED=1
}

control_restore_monitor() {
  if [ "$CONTROL_MONITOR_WAS" = on ]; then
    set -m
  else
    set +m
  fi
}

control_close_gate() {
  if [ "$CONTROL_GATE_OPEN" -eq 1 ]; then
    exec 7>&- || return 1
    CONTROL_GATE_OPEN=0
  fi
}

control_remove_gate() {
  [ -z "$CONTROL_GATE_PATH" ] || /bin/rm -- "$CONTROL_GATE_PATH"
}

control_release_job() {
  control_phase release-possible || return 1
  CONTROL_POSSIBLY_RELEASED=1
  /usr/bin/printf '%s\n' verified >&7 || return 1
  control_close_gate || return 1
  control_remove_gate || return 1
  control_phase wait-only
}

control_abort_job() {
  if [ "$CONTROL_GATE_OPEN" -eq 1 ]; then
    /usr/bin/printf '%s\n' abort >&7 || :
    control_close_gate || :
  fi
  [ -z "$CONTROL_GATE_PATH" ] || /bin/rm -f -- "$CONTROL_GATE_PATH" || :
}

control_wait_job() {
  local status
  [ "$CONTROL_JOB_ACQUIRED" -eq 1 ] || return 1
  CONTROL_RETAIN_SCRATCH=1
  while :; do
    CONTROL_WAIT_INTERRUPTED=0
    CONTROL_WAIT_ACTIVE=1
    status=0
    builtin wait "$CONTROL_JOB" || status=$?
    CONTROL_WAIT_ACTIVE=0
    if [ "$CONTROL_WAIT_INTERRUPTED" -eq 1 ]; then
      continue
    fi
    [ "$status" -ne 127 ] || return 1
    CONTROL_WAIT_STATUS=$status
    CONTROL_WAIT_STATUS_STATE=confirmed
    break
  done
}

control_retire_job() {
  [ "$CONTROL_WAIT_STATUS_STATE" = confirmed ] || return 1
  CONTROL_JOB_ACQUIRED=0
  CONTROL_JOB=
  control_phase retired
}

control_excerpt() {
  local path=$1
  [ -f "$path" ] || return 0
  /usr/bin/perl -e '
    use strict;
    use warnings;
    my ($path) = @ARGV;
    open(my $fh, "<", $path) or exit 1;
    binmode($fh);
    my $count = read($fh, my $text, 256);
    defined($count) or exit 2;
    close($fh) or exit 3;
    $text =~ s/([^\x20-\x7e])/sprintf("\\x%02x", ord($1))/ge;
    print $text or exit 4;
  ' "$path"
}

control_diagnostic() {
  local identity_excerpt= events_excerpt= stderr_excerpt= record
  identity_excerpt=$(control_excerpt "${CONTROL_IDENTITY_PATH:-}") || identity_excerpt=read-error
  events_excerpt=$(control_excerpt "${control_events:-}") || events_excerpt=read-error
  stderr_excerpt=$(control_excerpt "${control_stderr:-}") || stderr_excerpt=read-error
  record=$(/usr/bin/printf \
    'credential-handoff: phase=%s outcome=%s signal=%s acquired=%s wait=%s possible_release=%s identity=%s events=%s stderr=%s' \
    "$CONTROL_PHASE" "${CONTROL_FAILURE:-unknown}" "${CONTROL_SIGNAL:-none}" \
    "$CONTROL_JOB_ACQUIRED" "${CONTROL_WAIT_STATUS_STATE}:${CONTROL_WAIT_STATUS:-none}" \
    "$CONTROL_POSSIBLY_RELEASED" "$identity_excerpt" "$events_excerpt" "$stderr_excerpt") || return 1
  PERL5LIB= PERLLIB= PERL5OPT= /usr/bin/perl -e '
    use strict;
    use warnings;
    my $text = <STDIN>;
    defined($text) or exit 1;
    print substr($text, 0, 2047), "\n" or exit 2;
  ' <<<"$record"
}

control_reconcile_failure() {
  control_record_failure "$1"
  CONTROL_RETAIN_SCRATCH=1
  if [ "$CONTROL_JOB_ACQUIRED" -eq 1 ]; then
    if [ "$CONTROL_POSSIBLY_RELEASED" -eq 0 ]; then
      control_abort_job
    fi
    case "$CONTROL_PHASE" in wait-only) ;; *) CONTROL_PHASE=wait-only ;; esac
    if control_wait_job; then
      control_retire_job || control_record_failure retirement
    else
      CONTROL_WAIT_STATUS_STATE=unconfirmed
    fi
  fi
  control_diagnostic >&2 || :
}

control_complete() {
  control_phase inspected || return 1
  control_phase complete || return 1
  CONTROL_CONTEXT=0
  CONTROL_RETAIN_SCRATCH=0
  CONTROL_CASE_PATH=
  CONTROL_IDENTITY_PATH=
  CONTROL_GATE_PATH=
}

setup_control_fail() {
  control_reconcile_failure "$1"
  fail "$1"
}
run_setup_controls() {
  local control_root="$tmp/setup-controls" functions name signal code status started elapsed
  local child reported group function_name attempt signals control_events launches mutations
  local helpers reconciled event_kind leader expected_launches expected_helpers expected_error
  local control_owner='' observers term_count cont_count kill_count
  local identity_fields identity_status field_status control_stderr
  /bin/mkdir "$control_root"
  functions="$control_root/functions.sh"
  : >"$functions"
  for function_name in managed_enter managed_operation managed_lifecycle managed_outcome \
    managed_release managed_kill managed_wait managed_reap managed_probe_command managed_probe managed_pending \
    managed_end_operation managed_terminate managed_dispatch managed_clear_attempt \
    managed_inspect_scratch managed_preserve_output coordinate_input_setup \
    terminate_input_race group_alive managed_gate_remove managed_launch_group \
    start_input_race stop_at_owned_marker fail; do
    declare -f "$function_name" >>"$functions"
  done
  cat >"$control_root/fixture.sh" <<'FIXTURE'
#!/bin/bash
set -eu
trap 'rm -rf "$TMPDIR/owned"; exit 0' HUP INT TERM
mkdir "$TMPDIR/owned"
printf '%s\n' "$$" >"$TMPDIR/owned/input-snapshot-pending"
printf '%s\n' ready >"$TMPDIR/owned/input-snapshot-ready"
while :; do IFS= read -r -t 1 token <&9 || :; done
FIXTURE
  /bin/chmod 0500 "$control_root/fixture.sh"
  cat >"$control_root/control.sh" <<'CONTROL'
#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077
base=$1
case_name=$2
injected_signal=$3
source "$base/functions.sh"
tmp="$base/$case_name-$injected_signal"
log="$tmp/events"
[ -d "$tmp" ] && [ -d "$tmp/scratch" ] && [ -f "$log" ] || exit 89
event() { printf '%s\n' "$*" >>"$log"; }
SETUP_CONTEXT=0 SETUP_OPERATION=none SETUP_LIFECYCLE=empty SETUP_OUTCOME=
SETUP_SIGNAL= WAIT_INTERRUPTED=0 WAIT_STATUS=0 LOCAL_REAP_ACTIVE=0 LOCAL_REAP_PID=
INPUT_RACE_PID= INPUT_RACE_PGID= STOPPED_MARKER_PATH= PROBE_RESULT=error
INPUT_RACE_OUT= INPUT_RACE_ERR= LAUNCH_GROUP=
SIGNAL_CHILD_PID= SIGNAL_CHILD_PGID= SIGNAL_DESCENDANT_PID=
CONTROL_CONTEXT=0 CONTROL_PHASE=inactive CONTROL_FAILURE= CONTROL_SIGNAL=
CONTROL_JOB= CONTROL_JOB_ACQUIRED=0 CONTROL_WAIT_ACTIVE=0 CONTROL_WAIT_INTERRUPTED=0
CONTROL_WAIT_STATUS= CONTROL_WAIT_STATUS_STATE=unconfirmed CONTROL_POSSIBLY_RELEASED=0
CONTROL_RETAIN_SCRATCH=0 CONTROL_GATE_OPEN=0 CONTROL_GATE_PATH= CONTROL_CASE_PATH=
CONTROL_IDENTITY_PATH= CONTROL_MONITOR_WAS=off
startup_exit() {
  local status=$1
  trap - EXIT HUP INT TERM
  exec 6>&- 2>/dev/null || :
  exec 7>&- 2>/dev/null || :
  exit "$status"
}
trap 'startup_exit 92' EXIT
trap 'startup_exit 129' HUP
trap 'startup_exit 130' INT
trap 'startup_exit 143' TERM
TEST_PGID=$(ps -o pgid= -p $$ | tr -d ' ')
[[ "$TEST_PGID" =~ ^[1-9][0-9]*$ ]] || exit 90
[[ "$$" =~ ^[1-9][0-9]*$ ]] && [ "$$" = "$TEST_PGID" ] || exit 90
identity_tmp="$tmp/identity.tmp"
identity_final="$tmp/identity"
[ ! -e "$identity_tmp" ] && [ ! -L "$identity_tmp" ] &&
  [ ! -e "$identity_final" ] && [ ! -L "$identity_final" ] || exit 90
exec 6>"$identity_tmp" || exit 90
printf '%s %s\n' "$$" "$TEST_PGID" >&6 || exit 90
exec 6>&- || exit 90
mv "$identity_tmp" "$identity_final" || exit 90
token=
gate_status=0
IFS= read -r -t "${CONTROL_GATE_SECONDS:-3}" token <&7 || gate_status=$?
exec 7>&- || exit 91
[ "$gate_status" -eq 0 ] && [ "$token" = verified ] || exit 91
trap - EXIT HUP INT TERM
injected=0 launches=0 helpers=0 physical_waits=0 logical_reaps=0 probes=0
cleanup() { event "exit-state $SETUP_LIFECYCLE $SETUP_OPERATION $LOCAL_REAP_ACTIVE"; }
trap 'managed_dispatch EXIT' EXIT
trap 'managed_dispatch HUP' HUP
trap 'managed_dispatch INT' INT
trap 'managed_dispatch TERM' TERM
save() {
  local text
  text=$(declare -f "$1")
  eval "${text/$1 ()/actual_$1 ()}"
}
inject() {
  if [ "$injected" -eq 0 ]; then
    injected=1
    event "signal $injected_signal $$"
    /bin/kill -"$injected_signal" "$$"
  fi
}
for fn in managed_enter managed_operation managed_lifecycle managed_outcome \
  managed_kill managed_wait managed_reap managed_probe_command managed_probe managed_terminate start_input_race \
  stop_at_owned_marker managed_clear_attempt managed_inspect_scratch \
  managed_preserve_output managed_gate_remove managed_launch_group terminate_input_race; do save "$fn"; done
terminate_input_race() {
  event termination
  actual_terminate_input_race "$@"
}
managed_enter() {
  actual_managed_enter
  event entry
  [ "$case_name" != entry ] || inject
}
managed_operation() {
  actual_managed_operation "$1"
  event "operation $1"
  if [ "$1" = launching ] && [ "$launches" -eq 1 ] &&
     [ "$case_name" = next-after ]; then inject; fi
  if [ "$1" = none ] && [ "$SETUP_LIFECYCLE" = retired ]; then
    [ "$case_name" != helper-return ] || inject
  fi
  if [ "$1" = none ] && [ "$SETUP_OUTCOME" = missed-window ] &&
     [ "$SETUP_LIFECYCLE" = owned-live ]; then
    [ "$case_name" != observer-return ] || inject
  fi
}
managed_lifecycle() {
  actual_managed_lifecycle "$1"
  event "lifecycle $1"
  if [ "$1" = owned-live ]; then
    event "owned $INPUT_RACE_PID $INPUT_RACE_PGID"
    [ "$case_name" != admission ] || inject
    if [ "$case_name" = release-error ]; then exec 8>&-; fi
  fi
  if [ "$1" = wait-in-progress ] && [ "$case_name" = pre-wait ]; then inject; fi
  if [ "$1" = retired-unconfirmed ] && [ "$case_name" = retired-probe ]; then inject; fi
}
managed_outcome() {
  actual_managed_outcome "$1"
  event "outcome $1"
  if [ "$1" = missed-window ] && [ "$case_name" = classification ]; then inject; fi
}
managed_kill() {
  event "kill $*"
  actual_managed_kill "$@"
}
managed_wait() {
  physical_waits=$((physical_waits + 1))
  actual_managed_wait "$1"
  event "physical-wait $1 $WAIT_STATUS"
  case "$case_name:$LOCAL_REAP_ACTIVE" in
    group-reap:0|local-reap:1) inject ;;
    wait127-group:0|wait127-local:1) WAIT_STATUS=127 ;;
    wait-natural:0) WAIT_STATUS=143 ;;
    wait-interrupt:0)
      if [ "$physical_waits" -eq 1 ]; then WAIT_STATUS=143; WAIT_INTERRUPTED=1; fi ;;
  esac
  event "wait-result $WAIT_STATUS $WAIT_INTERRUPTED"
}
managed_reap() {
  logical_reaps=$((logical_reaps + 1))
  event "logical-reap $1 $2"
  actual_managed_reap "$@"
}
managed_probe_command() {
  if [ "$case_name" = probe-poll-error ] && [ "$probes" -eq 0 ]; then
    printf error
    return
  fi
  if [ "$SETUP_LIFECYCLE" = retired-unconfirmed ]; then
    case "$case_name" in
      probe-alive) printf alive; return ;;
      probe-error) printf error; return ;;
      probe-malformed) printf invalid; return ;;
      probe-exec) /nonexistent/credential-private-probe; return ;;
      probe-status) printf absent; return 1 ;;
    esac
  fi
  actual_managed_probe_command "$1"
}
managed_probe() {
  actual_managed_probe "$1"
  probes=$((probes + 1))
  event "probe $PROBE_RESULT $SETUP_LIFECYCLE"
}

managed_terminate() {
  helpers=$((helpers + 1))
  event helper
  actual_managed_terminate
}
start_input_race() {
  launches=$((launches + 1))
  event launch
  actual_start_input_race "$@"
}
stop_at_owned_marker() {
  event observer
  actual_stop_at_owned_marker "$@"
}
managed_clear_attempt() {
  actual_managed_clear_attempt
  event reconciled
  [ "$case_name" != next-before ] || inject
}
managed_inspect_scratch() {
  if [ "$case_name" = inspect-error ]; then mv "$1" "$1.moved"; fi
  actual_managed_inspect_scratch "$1"
}
managed_preserve_output() {
  if [ "$case_name" = preserve-error ]; then mv "$tmp" "$tmp.moved"; log="$tmp.moved/events"; fi
  actual_managed_preserve_output "$@"
}
managed_launch_group() {
  actual_managed_launch_group "$1"
  case "$case_name" in local-error|local-reap|wait127-local) LAUNCH_GROUP=invalid ;; esac
}
managed_gate_remove() {
  case "$case_name" in local-error|local-reap|wait127-local|release-error)
    /bin/rm -f "$1"
    mkdir "$1"
    : >"$1/held"
    event gate-file-error ;;
  esac
  actual_managed_gate_remove "$1"
}
bin=/usr/bin evaluator="$base/fixture.sh"
policy_set=unused request=unused resolved=unused result=unused duty=unused
mkfifo "$tmp/hold"
exec 9<>"$tmp/hold"
case "$case_name" in
  coordinator-*)
    start_input_race() {
      launches=$((launches + 1)); event launch
      INPUT_RACE_PID= INPUT_RACE_PGID=
      [ "$case_name" != coordinator-error ] || fail 'controlled setup error'
    }
    stop_at_owned_marker() {
      if [ "$case_name" = coordinator-success ] && [ "$launches" -eq 2 ]; then
        managed_outcome stopped
      else managed_outcome missed-window; fi
    }
    managed_terminate() {
      event termination
      [ "$case_name" != coordinator-cleanup ] || fail 'controlled cleanup error'
      managed_lifecycle retired
    }
    managed_inspect_scratch() { event inspection; }
    managed_preserve_output() { event preservation; }
    ;;
  reject-invalid|reject-own)
    managed_enter
    if [ "$case_name" = reject-own ]; then INPUT_RACE_PID=$TEST_PGID
    else INPUT_RACE_PID=invalid; fi
    INPUT_RACE_PGID=$INPUT_RACE_PID
    managed_lifecycle owned-live
    managed_terminate
    exit 92 ;;
  absence|group-reap|helper-return|pre-wait|retired-probe|probe-*|wait127-group|wait-natural|wait-interrupt)
    managed_enter
    managed_operation launching
    start_input_race fixture "$tmp/scratch" unused
    managed_end_operation
    managed_operation observing
    stop_at_owned_marker fixture "$tmp/scratch" input-snapshot-pending \
      input-snapshot-ready setup-miss
    managed_end_operation
    managed_terminate
    managed_clear_attempt
    managed_release
    event completed
    exit 0 ;;
esac
coordinate_input_setup fixture "$tmp/scratch" unused
event mutation
exit 0
CONTROL
  for name in coordinator-success coordinator-exhaust coordinator-error coordinator-cleanup \
    entry admission classification observer-return next-before next-after local-error \
    local-reap release-error inspect-error preserve-error group-reap helper-return \
    pre-wait retired-probe reject-invalid reject-own absence probe-alive probe-error \
    probe-malformed probe-exec probe-status probe-poll-error wait127-group wait127-local wait-natural wait-interrupt; do
    case "$name" in
      entry|admission|classification|observer-return|next-before|next-after|local-reap|\
      group-reap|helper-return|pre-wait|retired-probe) signals='HUP INT TERM' ;;
      *) signals=none ;;
    esac
    for signal in $signals; do
      control_enter
      code="$control_root/$name-$signal"
      CONTROL_CASE_PATH=$code
      CONTROL_IDENTITY_PATH="$code/identity"
      control_events="$code/events"
      control_stderr="$control_root/$name-$signal.stderr"
      started=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
      /bin/mkdir "$code" "$code/scratch" || setup_control_fail "$name control directory"
      : >"$control_events" || setup_control_fail "$name control events"
      : >"$control_root/$name-$signal.stdout" || setup_control_fail "$name control stdout"
      : >"$control_stderr" || setup_control_fail "$name control stderr"
      control_phase prepared || setup_control_fail "$name control prepare phase"
      CONTROL_GATE_PATH="$control_root/start"
      /usr/bin/mkfifo "$CONTROL_GATE_PATH" || setup_control_fail "$name control gate"
      exec 7<>"$CONTROL_GATE_PATH" || setup_control_fail "$name control gate open"
      CONTROL_GATE_OPEN=1
      set -m || setup_control_fail "$name monitor enable"
      control_launch_job "$control_root/control.sh" "$control_root" "$name" "$signal" \
        "$control_root/$name-$signal.stdout" "$control_stderr"
      child=$CONTROL_JOB
      control_owner=$child
      control_phase launched || setup_control_fail "$name control launch phase"
      control_restore_monitor || setup_control_fail "$name monitor restore"
      attempt=0
      while ! control_identity_present "$CONTROL_IDENTITY_PATH" && [ "$attempt" -lt 100 ]; do
        /bin/sleep 0.01
        attempt=$((attempt + 1))
      done
      control_identity_present "$CONTROL_IDENTITY_PATH" || setup_control_fail "$name control identity"
      identity_fields=
      identity_status=0
      identity_fields=$(control_identity_read "$CONTROL_IDENTITY_PATH") || identity_status=$?
      [ "$identity_status" -eq 0 ] || setup_control_fail "$name control identity invalid"
      reported=
      group=
      field_status=0
      IFS=' ' read -r reported group <<<"$identity_fields" || field_status=$?
      [ "$field_status" -eq 0 ] && [ -n "$reported" ] && [ -n "$group" ] ||
        setup_control_fail "$name control identity fields"
      control_phase identified || setup_control_fail "$name control identity phase"
      [ "$reported" = "$child" ] && [ "$group" = "$child" ] &&
        [ "$group" != "$TEST_PGID" ] ||
        setup_control_fail "$name control shell ownership"
      control_pending || setup_control_fail "$name control pending signal"
      control_release_job || setup_control_fail "$name control release"
      control_wait_job || setup_control_fail "$name control wait unconfirmed"
      status=$CONTROL_WAIT_STATUS
      control_retire_job || setup_control_fail "$name control retirement"
      control_owner=
      elapsed=$(/usr/bin/perl -MTime::HiRes=time -e \
        'printf "%.3f", time-$ARGV[0]' "$started")
      code="$control_root/$name-$signal"
      [ ! -d "$code.moved" ] || code="$code.moved"
      [ -f "$code/events" ] || setup_control_fail "$name missing control events"
      control_events="$code/events"
      launches=$(/usr/bin/grep -c '^launch$' "$control_events" || :)
      mutations=$(/usr/bin/grep -c '^mutation$' "$control_events" || :)
      helpers=$(/usr/bin/grep -c '^termination$' "$control_events" || :)
      reconciled=$(/usr/bin/grep -c '^reconciled$' "$control_events" || :)
      case "$name" in
        coordinator-success)
          [ "$status:$launches:$helpers:$mutations:$reconciled" = 0:2:1:1:1 ] ||
            setup_control_fail 'coordinator miss-then-success control' ;;
        coordinator-exhaust)
          { [ "$status:$launches:$helpers:$mutations:$reconciled" = 1:3:3:0:3 ] &&
            /usr/bin/grep -q 'setup attempts exhausted' "$control_root/$name-$signal.stderr"; } ||
            setup_control_fail 'coordinator exhaustion control' ;;
        coordinator-error|coordinator-cleanup)
          [ "$status:$launches:$mutations" = 1:1:0 ] || setup_control_fail "$name count" ;;
        absence|wait-natural|wait-interrupt)
          { [ "$status:$launches:$helpers:$mutations" = 0:1:1:0 ] &&
            /usr/bin/grep -q '^completed$' "$control_events"; } || setup_control_fail "$name completion" ;;
        *)
          [ "$status" -ne 0 ] && [ "$mutations" -eq 0 ] || setup_control_fail "$name terminal control"
          [ "$launches" -le 2 ] && [ "$helpers" -le 2 ] || setup_control_fail "$name repeated cleanup"
          ;;
      esac
      case "$name" in
        entry)
          [ "$launches:$helpers" = 0:0 ] || setup_control_fail "$name premature launch" ;;
        admission|classification|observer-return|group-reap|helper-return|pre-wait|retired-probe)
          [ "$launches:$helpers" = 1:1 ] || setup_control_fail "$name single cleanup" ;;
        next-before|next-after)
          expected_launches=1 expected_helpers=1
          if [ "$name" = next-after ]; then expected_launches=2; expected_helpers=2; fi
          [ "$launches:$helpers:$reconciled" = "$expected_launches:$expected_helpers:1" ] ||
            setup_control_fail "$name handoff counts" ;;
        local-error|local-reap|wait127-local)
          { [ "$launches:$helpers" = 1:0 ] &&
            [ "$(/usr/bin/grep -c '^kill -KILL [0-9]' "$control_events")" -eq 1 ] &&
            [ "$(/usr/bin/grep -c '^logical-reap .* local$' "$control_events")" -eq 1 ] &&
            /usr/bin/grep -q 'unsafe evaluator process group' "$control_root/$name-$signal.stderr" &&
            /usr/bin/grep -q '^gate-file-error$' "$control_events"; } ||
            setup_control_fail "$name actual local abort" ;;
        release-error)
          { [ "$launches:$helpers" = 1:1 ] &&
            /usr/bin/grep -q 'launch release' "$control_root/$name-$signal.stderr" &&
            /usr/bin/grep -q '^gate-file-error$' "$control_events"; } || setup_control_fail "$name actual release" ;;
        inspect-error|preserve-error)
          [ "$launches:$helpers:$reconciled" = 1:1:0 ] || setup_control_fail "$name retired counts"
          if [ "$name" = inspect-error ]; then expected_error='setup scratch inspection failed'
          else expected_error='setup output preservation failed'; fi
          /usr/bin/grep -q "$expected_error" "$control_root/$name-$signal.stderr" ||
            setup_control_fail "$name named file error" ;;
        reject-invalid|reject-own)
          { [ "$launches:$helpers" = 0:1 ] &&
            ! /usr/bin/grep -q '^kill ' "$control_events" &&
            /usr/bin/grep -q '^lifecycle rejected-before-signal$' "$control_events"; } ||
            setup_control_fail "$name no signal" ;;
        probe-*|wait127-group)
          { [ "$launches:$helpers" = 1:1 ] &&
            /usr/bin/grep -q 'setup cleanup unconfirmed' "$control_root/$name-$signal.stderr" &&
            ! /usr/bin/grep -q '^lifecycle retired$' "$control_events"; } ||
            setup_control_fail "$name unconfirmed cleanup" ;;
      esac
      observers=$(/usr/bin/grep -c '^observer$' "$control_events" || :)
      case "$name" in
        entry|admission|local-error|local-reap|wait127-local|release-error)
          [ "$observers" -eq 0 ] || setup_control_fail "$name observed after terminal setup" ;;
        classification|observer-return|next-before|next-after)
          [ "$observers" -eq 1 ] || setup_control_fail "$name observer count" ;;
        coordinator-error)
          [ "$helpers:$reconciled" = 0:0 ] || setup_control_fail "$name unexpected cleanup" ;;
        coordinator-cleanup)
          [ "$helpers:$reconciled" = 1:0 ] || setup_control_fail "$name retried failed cleanup" ;;
      esac
      case "$name" in coordinator-*|entry|local-error|local-reap|wait127-local|reject-*) ;;
        *)
          term_count=$(/usr/bin/grep -c '^kill -TERM -- ' "$control_events" || :)
          cont_count=$(/usr/bin/grep -c '^kill -CONT -- ' "$control_events" || :)
          kill_count=$(/usr/bin/grep -c '^kill -KILL -- ' "$control_events" || :)
          [ "$term_count:$cont_count" = "$helpers:$helpers" ] &&
            [ "$kill_count" -le "$helpers" ] &&
            [ "$(/usr/bin/grep -c '^logical-reap .* group$' "$control_events")" -eq "$helpers" ] ||
            setup_control_fail "$name repeated signal or reap budget" ;;
      esac
      case "$name" in group-reap|local-reap|wait-interrupt)
        [ "$(/usr/bin/grep -c '^physical-wait ' "$control_events")" -ge 2 ] &&
          [ "$(/usr/bin/grep -c '^logical-reap ' "$control_events")" -eq 1 ] ||
          setup_control_fail "$name wait-only repetition" ;;
      esac
      case "$name" in group-reap|helper-return|pre-wait|retired-probe|absence|wait-natural|wait-interrupt)
        { /usr/bin/grep -q '^probe absent retired-unconfirmed$' "$control_events" &&
          /usr/bin/grep -q '^lifecycle retired$' "$control_events"; } || setup_control_fail "$name real final probe" ;;
      esac
      if [ "$signal" != none ]; then
        { [ "$(/usr/bin/grep -c '^signal ' "$control_events")" -eq 1 ] &&
          /usr/bin/grep -q "setup terminal: $signal" "$control_root/$name-$signal.stderr"; } ||
          setup_control_fail "$name signal boundary"
      fi
      case "$name" in local-error|local-reap|wait127-local)
        while read -r event_kind leader group; do
          [ "$event_kind:$group" = logical-reap:local ] || continue
          /usr/bin/perl -MErrno=ESRCH -e \
            'exit((kill(0,$ARGV[0]) == 0 && $! == ESRCH) ? 0 : 1)' "$leader" ||
            setup_control_fail "$name local child remains"
        done <"$control_events"
        /usr/bin/grep -q '^exit-state empty none 0$' "$control_events" ||
          setup_control_fail "$name local authority not retired"
        ;;
      esac
      case "$name" in wait127-local)
        /usr/bin/grep -q 'setup local reap unconfirmed' "$control_root/$name-$signal.stderr" ||
          setup_control_fail "$name unconfirmed local result" ;;
      wait-natural)
        { [ "$(/usr/bin/grep -c '^physical-wait ' "$control_events")" -eq 1 ] &&
          /usr/bin/grep -q '^wait-result 143 0$' "$control_events"; } ||
          setup_control_fail "$name natural status repeated" ;;
      esac
      while read -r event_kind leader group; do
        [ "$event_kind" = owned ] || continue
        case "$name" in reject-invalid|reject-own) continue ;; esac
        [[ "$leader" =~ ^[1-9][0-9]*$ ]] && [ "$leader" = "$group" ] ||
          setup_control_fail "$name recorded group"
        /usr/bin/perl -MErrno=ESRCH -e \
          'exit((kill(0,-$ARGV[0]) == 0 && $! == ESRCH) ? 0 : 1)' "$group" ||
          setup_control_fail "$name fixture descendants"
      done <"$control_events"
      /usr/bin/printf 'setup-control-events: %s %s\n' "$name" "$signal"
      /bin/cat "$control_events"
      /usr/bin/printf 'setup-control: %s %s elapsed=%ss launches=%s helpers=%s\n' \
        "$name" "$signal" "$elapsed" "$launches" "$helpers"
      pass "setup-control $name $signal"
      control_complete || setup_control_fail "$name control completion"
    done
  done
}

start_input_race() {
  local name=$1 scratch_root=$2 claim_path=$3
  local race_evaluator=${4:-$evaluator} gate leader pgid attempt=0 launch_error=0
  gate="$tmp/$name.launch.gate"
  INPUT_RACE_OUT="$tmp/$name.out"
  INPUT_RACE_ERR="$tmp/$name.err"
  /usr/bin/mkfifo "$gate" || fail "$name launch gate"
  exec 8<>"$gate" || fail "$name launch gate open"
  set -m
  /bin/bash -c '
    IFS= read -r token <&8 || exit 125
    exec 8>&-
    [ "$token" = go ] || exit 125
    race_tmp=$1
    race_path=$2
    shift 2
    TMPDIR=$race_tmp PATH=$race_path exec "$@"
  ' input-race "$scratch_root" "$bin:/usr/bin:/bin" "$race_evaluator" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim_path" \
    >"$INPUT_RACE_OUT" 2>"$INPUT_RACE_ERR" &
  leader=$!
  set +m || launch_error=1
  if [ "$SETUP_CONTEXT" -eq 1 ]; then
    LAUNCH_GROUP=
    while [ -z "$LAUNCH_GROUP" ] && [ "$attempt" -lt 100 ] &&
          [ "$launch_error" -eq 0 ]; do
      managed_launch_group "$leader" || launch_error=1
      if [ -z "$LAUNCH_GROUP" ]; then
        /bin/sleep 0.01 || launch_error=1
      fi
      attempt=$((attempt + 1))
    done
    pgid=$LAUNCH_GROUP
    if [[ ! "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$leader" ] ||
       [ "$pgid" = "$TEST_PGID" ]; then launch_error=1; fi
    if [ "$launch_error" -ne 0 ]; then
      /usr/bin/printf 'abort\n' >&8 || launch_error=1
      exec 8>&- || launch_error=1
      managed_gate_remove "$gate" || launch_error=1
      managed_kill -KILL "$leader" 2>/dev/null || launch_error=1
      LOCAL_REAP_PID=$leader
      LOCAL_REAP_ACTIVE=1
      managed_reap "$leader" local ||
        /usr/bin/printf '%s\n' 'setup local reap unconfirmed' >&2
      /usr/bin/printf '%s\n' "$name unsafe evaluator process group" >&2
      managed_end_operation
      fail "$name unsafe evaluator process group"
    fi
    INPUT_RACE_PID=$leader
    INPUT_RACE_PGID=$pgid
    managed_lifecycle owned-live
    /usr/bin/printf 'go\n' >&8 || launch_error=1
    exec 8>&- || launch_error=1
    managed_gate_remove "$gate" || launch_error=1
    if [ "$launch_error" -ne 0 ]; then
      /usr/bin/printf '%s\n' "$name launch release" >&2
      managed_terminate
      fail "$name launch release"
    fi
    return
  fi
  pgid=
  while [ -z "$pgid" ] && /bin/kill -0 "$leader" 2>/dev/null &&
    [ "$attempt" -lt 100 ]; do
    pgid=$(/bin/ps -o pgid= -p "$leader" 2>/dev/null |
      /usr/bin/tr -d ' ') || pgid=
    [ -n "$pgid" ] || /bin/sleep 0.01
    attempt=$((attempt + 1))
  done
  if [[ ! "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$leader" ] ||
     [ "$pgid" = "$TEST_PGID" ]; then
    /usr/bin/printf 'abort\n' >&8 || :
    exec 8>&-
    /bin/rm -f -- "$gate"
    /bin/kill -KILL "$leader" 2>/dev/null || :
    wait "$leader" 2>/dev/null || :
    fail "$name unsafe evaluator process group"
  fi
  INPUT_RACE_PID=$leader
  INPUT_RACE_PGID=$pgid
  /usr/bin/printf 'go\n' >&8 || {
    exec 8>&-
    /bin/rm -f -- "$gate"
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name launch release"
  }
  exec 8>&-
  /bin/rm -f -- "$gate"
}

stop_at_owned_marker() {
  local name=$1 scratch_root=$2 marker_name=$3 forbidden_marker=${4:-}
  local attempt=0 marker owner state stop_attempt=0 selector=${5:-strict} found
  case "$selector:$SETUP_CONTEXT" in strict:*) ;; setup-miss:1) ;; *)
    fail 'invalid setup observer selector' ;; esac
  if [ "$selector" = setup-miss ]; then managed_outcome observing; fi
  marker=
  while [ -z "$marker" ] && [ "$attempt" -lt 5000 ]; do
    marker=$(/usr/bin/find "$scratch_root" -type f -name "$marker_name" \
      -print -quit 2>/dev/null) || {
        [ "$selector" = strict ] || fail "$name marker find failed"
        marker=
      }
    if [ -z "$marker" ] && ! /bin/kill -0 "$INPUT_RACE_PID" 2>/dev/null; then
      if [ "$selector" = setup-miss ]; then
        managed_terminate
        fail "$name evaluator exited before $marker_name"
      fi
      wait "$INPUT_RACE_PID" 2>/dev/null || :
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
      fail "$name evaluator exited before $marker_name"
    fi
    [ -n "$marker" ] || /bin/sleep 0.001
    attempt=$((attempt + 1))
  done
  [ -n "$marker" ] || {
    if [ "$selector" = setup-miss ]; then managed_terminate
    else terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :; fi
    if [ "$selector" = strict ]; then
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
    fi
    fail "$name marker timeout: $marker_name"
  }
  case "$marker" in "$scratch_root"/*/"$marker_name") ;; *)
    if [ "$selector" = setup-miss ]; then managed_terminate
    else terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :; fi
    if [ "$selector" = strict ]; then
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
    fi
    fail "$name marker escaped scratch"
  esac
  owner=$(/bin/cat "$marker")
  [ "$owner" = "$INPUT_RACE_PID" ] || {
    if [ "$selector" = setup-miss ]; then managed_terminate
    else terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :; fi
    if [ "$selector" = strict ]; then
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
    fi
    fail "$name marker owner mismatch"
  }
  /bin/kill -STOP -- "-$INPUT_RACE_PGID" || fail "$name stop evaluator group"
  state=
  while [ "$stop_attempt" -lt 100 ]; do
    state=$(/bin/ps -o state= -p "$INPUT_RACE_PID" 2>/dev/null |
      /usr/bin/tr -d ' ') || {
        [ "$selector" = strict ] || fail "$name stopped-state observation failed"
        state=
      }
    case "$state" in T*) break ;; esac
    /bin/sleep 0.01
    stop_attempt=$((stop_attempt + 1))
  done
  case "$state" in T*) ;; *)
    if [ "$selector" = setup-miss ]; then managed_terminate
    else terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :; fi
    if [ "$selector" = strict ]; then
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
    fi
    fail "$name evaluator group did not stop"
  esac
  if [ "$selector" = setup-miss ]; then
    [ "$INPUT_RACE_PID" = "$INPUT_RACE_PGID" ] &&
      [ "$INPUT_RACE_PGID" != "$TEST_PGID" ] &&
      [ "$SETUP_LIFECYCLE" = owned-live ] || fail "$name observer ownership"
    found=$(/usr/bin/find "$scratch_root" -type f -name "$forbidden_marker" \
      -print -quit) || fail "$name readiness find failed"
    STOPPED_MARKER_PATH=$marker
    if [ -n "$found" ]; then managed_outcome missed-window
    else managed_outcome stopped; fi
    return
  fi
  if [ -n "$forbidden_marker" ] &&
     /usr/bin/find "$scratch_root" -type f -name "$forbidden_marker" -print -quit |
       /usr/bin/grep -q .; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name missed guarded window before $forbidden_marker"
  fi
  STOPPED_MARKER_PATH=$marker
}

stop_at_input_pending() {
  stop_at_owned_marker "$1" "$2" input-snapshot-pending input-snapshot-ready
}

wait_evaluator_group() {
  local name=$1 attempt=0 state status=0
  while [ "$attempt" -lt 1000 ]; do
    state=$(/bin/ps -o state= -p "$INPUT_RACE_PID" 2>/dev/null |
      /usr/bin/tr -d ' ') || state=
    case "$state" in ''|Z*) break ;; esac
    /bin/sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ "$attempt" -ge 1000 ]; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name evaluator completion timeout"
  fi
  wait "$INPUT_RACE_PID" 2>/dev/null || status=$?
  if group_alive "$INPUT_RACE_PGID"; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name evaluator left descendants"
  fi
  INPUT_RACE_STATUS=$status
  INPUT_RACE_PID=
  INPUT_RACE_PGID=
}

resume_and_wait_input_race() {
  local name=$1
  /bin/kill -CONT -- "-$INPUT_RACE_PGID" || fail "$name resume evaluator group"
  wait_evaluator_group "$name"
}

signal_owned_child_group() {
  local name=$1 scratch_root=$2 attempt=0 marker leader group parent descendant
  local descendant_group leader_state descendant_state stop_attempt
  marker=
  while [ -z "$marker" ] && [ "$attempt" -lt 5000 ]; do
    marker=$(/usr/bin/find "$scratch_root" -type f -name duty-ready -print -quit \
      2>/dev/null) || marker=
    if [ -z "$marker" ] && ! /bin/kill -0 "$INPUT_RACE_PID" 2>/dev/null; then
      wait "$INPUT_RACE_PID" 2>/dev/null || :
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
      fail "$name evaluator exited before duty launch"
    fi
    [ -n "$marker" ] || /bin/sleep 0.001
    attempt=$((attempt + 1))
  done
  [ -n "$marker" ] || {
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name duty launch timeout"
  }
  case "$marker" in "$scratch_root"/*/duty-ready) ;; *)
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name duty marker escaped scratch"
  esac
  leader=
  group=
  attempt=0
  while [ -z "$leader" ] && [ "$attempt" -lt 5000 ] &&
    /bin/kill -0 "$INPUT_RACE_PID" 2>/dev/null; do
    leader=$(/bin/ps -axo pid=,ppid=,pgid=,state= |
      /usr/bin/awk -v parent="$INPUT_RACE_PID" \
        '$2 == parent && $1 == $3 && $4 !~ /^Z/ {print $1; exit}') || leader=
    if [ -n "$leader" ]; then
      group=$(/bin/ps -o pgid= -p "$leader" 2>/dev/null |
        /usr/bin/tr -d ' ') || group=
      parent=$(/bin/ps -o ppid= -p "$leader" 2>/dev/null |
        /usr/bin/tr -d ' ') || parent=
      if ! /bin/kill -0 "$leader" 2>/dev/null || [ "$group" != "$leader" ] ||
         [ "$parent" != "$INPUT_RACE_PID" ]; then
        leader=
        group=
      fi
    fi
    [ -n "$leader" ] || /bin/sleep 0.001
    attempt=$((attempt + 1))
  done
  if [[ ! "$leader" =~ ^[1-9][0-9]*$ ]] ||
     [[ ! "$group" =~ ^[1-9][0-9]*$ ]] || [ "$leader" != "$group" ] ||
     [ "$group" = "$INPUT_RACE_PGID" ] || [ "$group" = "$TEST_PGID" ]; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name invalid child ownership"
  fi
  SIGNAL_CHILD_PID=$leader
  SIGNAL_CHILD_PGID=$group
  descendant=
  attempt=0
  while [ -z "$descendant" ] && [ "$attempt" -lt 5000 ] &&
    /bin/kill -0 "$INPUT_RACE_PID" 2>/dev/null && group_alive "$group"; do
    descendant=$(/bin/ps -axo pid=,pgid=,state= |
      /usr/bin/awk -v group="$group" -v leader="$leader" \
        '$2 == group && $1 != leader && $3 !~ /^Z/ {print $1; exit}') ||
      descendant=
    if [ -n "$descendant" ]; then
      descendant_group=$(/bin/ps -o pgid= -p "$descendant" 2>/dev/null |
        /usr/bin/tr -d ' ') || descendant_group=
      if ! /bin/kill -0 "$descendant" 2>/dev/null ||
         [ "$descendant_group" != "$group" ]; then
        descendant=
      elif /bin/kill -STOP -- "-$group" 2>/dev/null; then
        stop_attempt=0
        leader_state=
        descendant_state=
        while [ "$stop_attempt" -lt 100 ]; do
          leader_state=$(/bin/ps -o state= -p "$leader" 2>/dev/null |
            /usr/bin/tr -d ' ') || leader_state=
          descendant_state=$(/bin/ps -o state= -p "$descendant" 2>/dev/null |
            /usr/bin/tr -d ' ') || descendant_state=
          case "$leader_state:$descendant_state" in T*:T*) break ;; esac
          /bin/sleep 0.01
          stop_attempt=$((stop_attempt + 1))
        done
        descendant_group=$(/bin/ps -o pgid= -p "$descendant" 2>/dev/null |
          /usr/bin/tr -d ' ') || descendant_group=
        if ! /bin/kill -0 "$leader" 2>/dev/null ||
           ! /bin/kill -0 "$descendant" 2>/dev/null ||
           [ "$descendant_group" != "$group" ] ||
           [[ "$leader_state" != T* ]] || [[ "$descendant_state" != T* ]]; then
          /bin/kill -CONT -- "-$group" 2>/dev/null || :
          descendant=
        fi
      else
        descendant=
      fi
    fi
    [ -n "$descendant" ] || /bin/sleep 0.001
    attempt=$((attempt + 1))
  done
  if [[ ! "$descendant" =~ ^[1-9][0-9]*$ ]] ||
     ! /bin/kill -0 "$leader" 2>/dev/null ||
     ! /bin/kill -0 "$descendant" 2>/dev/null || ! group_alive "$group"; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name child group was not live"
  fi
  SIGNAL_DESCENDANT_PID=$descendant
  /bin/kill -TERM "$INPUT_RACE_PID" || fail "$name signal delivery"
}

run_driver baseline
"$jq_bin" -e '.body.verdict=="inconclusive" and
  .body.reason_ids==["claim.provenance-unqualified"] and
  .kind=="credential_policy_evaluation"' "$tmp/baseline.out" >/dev/null ||
  fail 'baseline observation'
"$jq_bin" -S -c . "$tmp/baseline.out" >"$tmp/baseline.canonical"
/usr/bin/cmp -s "$tmp/baseline.out" "$tmp/baseline.canonical" ||
  fail 'baseline canonical output'
pass 'baseline remains provenance-unqualified'

YSTACK_TEST_CREDENTIAL='synthetic-must-not-be-read' run_driver ambient-environment
/usr/bin/cmp -s "$tmp/baseline.out" "$tmp/ambient-environment.out" ||
  fail 'ambient environment changed output'
pass 'ambient credential-like environment is ignored'

perl_inject_dir="$tmp/perl-inject"
perl_inject_marker="$tmp/perl-inject.marker"
/bin/mkdir "$perl_inject_dir"
/usr/bin/printf '%s\n' 'package YStackInjected;' \
  "BEGIN { open(my \$fh, '>', '$perl_inject_marker') or die; print \$fh 'loaded'; close \$fh; }" \
  '1;' >"$perl_inject_dir/YStackInjected.pm"
PERL5LIB="$perl_inject_dir" PERLLIB="$perl_inject_dir" \
  PERL5OPT=-MYStackInjected run_driver perl-environment
if [ -e "$perl_inject_marker" ] ||
   ! /usr/bin/cmp -s "$tmp/baseline.out" "$tmp/perl-environment.out"; then
  fail 'ambient Perl injection'
fi
pass 'Perl helper environment is cleared'

run_pure baseline-pure "$claim" inconclusive claim.provenance-unqualified
bad=$(mutate_claim incomplete '.body.declaration_status="incomplete" |
  .body.accesses=(.body.accesses[0:1])')
run_pure incomplete "$bad" inconclusive claim.incomplete
bad=$(mutate_claim malformed-access '.body.accesses[0].credentials="bad"')
run_pure malformed-access "$bad" violated claim.malformed
run_driver malformed-driver "$bad"
"$jq_bin" -e '.body.verdict=="violated" and
  (.body.reason_ids|index("claim.malformed")!=null)' "$tmp/malformed-driver.out" \
  >/dev/null || fail 'malformed driver verdict'
pass 'malformed claim returns a canonical violation'
bad=$(mutate_claim direct '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].delivery="direct" else . end')
run_pure direct "$bad" violated credential.direct-delivery
bad=$(mutate_claim exposed '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].exposure="present" else . end')
run_pure exposed "$bad" violated credential.material-exposed
bad=$(mutate_claim persistent '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].scope="persistent" else . end')
run_pure persistent "$bad" violated credential.scope-denied
bad=$(mutate_claim wrong-class '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].credential_class="forge-write" else . end')
run_pure wrong-class "$bad" violated credential.ceiling-denied
bad=$(mutate_claim wrong-class-unknown '.body.accesses[] |=
  if (.credentials|length)>0 then
    .credentials[0].credential_class="forge-write" |
    .credentials[0].delivery="unknown"
  else . end')
run_pure wrong-class-unknown "$bad" violated credential.class-role-denied
bad=$(mutate_claim verifier-access '.body.accesses[] |=
  if .actor.role=="verifier" then .credentials=[{credential_class:"model-inference",
    delivery:"brokered",exposure:"none",scope:"single-stage"}] else . end')
run_pure verifier-access "$bad" violated credential.incompatible-permission
bad=$(mutate_claim actor-mismatch '.body.accesses[0].actor.principal_id="principal.other"')
run_pure actor-mismatch "$bad" violated claim.actor-or-binding-mismatch
bad=$(mutate_claim missing-binding 'del(.body.accesses[0])')
run_pure missing-binding "$bad" violated claim.binding-set-incomplete
bad=$(mutate_claim extra-binding '.body.accesses += [{actor:.body.accesses[0].actor,
  binding_id:"binding.extra",credentials:[]}] | .body.accesses|=sort_by(.binding_id)')
run_pure extra-binding "$bad" violated claim.binding-extra
bad=$(mutate_claim stale-set '.body.policy_set_ref.sha256=("0"*64)')
run_pure stale-set "$bad" violated claim.policy-set-ref-mismatch
bad=$(mutate_claim stale-duty '.body.duty_evaluation_ref.sha256=("0"*64)')
run_pure stale-duty "$bad" violated claim.duty-ref-mismatch
bad=$(mutate_claim stale-result '.body.stage_result_ref.sha256=("0"*64)')
run_pure stale-result "$bad" violated claim.stage-result-ref-mismatch
bad=$(mutate_claim unknown '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].delivery="unknown" else . end')
run_pure unknown "$bad" inconclusive credential.access-unknown

duty_violated="$tmp/duty-violated.json"
"$jq_bin" -S -c '.body.verdict="violated" |
  .body.reason_ids=["publisher.requested"]' "$duty" >"$duty_violated"
duty_violated_sha=$(sha256_path "$duty_violated")
duty_violated_claim="$tmp/duty-violated.claim"
"$jq_bin" -S -c --arg sha "$duty_violated_sha" \
  '.body.duty_evaluation_ref.sha256=$sha' "$claim" >"$duty_violated_claim"
run_pure duty-violated "$duty_violated_claim" violated duty.violated "$duty_violated"
duty_inconclusive="$tmp/duty-inconclusive.json"
"$jq_bin" -S -c '.body.verdict="inconclusive" |
  .body.reason_ids=["actual.capability-unclassified"]' "$duty" >"$duty_inconclusive"
duty_inconclusive_sha=$(sha256_path "$duty_inconclusive")
duty_inconclusive_claim="$tmp/duty-inconclusive.claim"
"$jq_bin" -S -c --arg sha "$duty_inconclusive_sha" \
  '.body.duty_evaluation_ref.sha256=$sha' "$claim" >"$duty_inconclusive_claim"
run_pure duty-inconclusive "$duty_inconclusive_claim" inconclusive duty.inconclusive \
  "$duty_inconclusive"

while IFS= read -r output; do
  "$jq_bin" -e '.body.verdict != "satisfied" and
    (.body.reason_ids | index("credential-policy.satisfied") == null)' "$output" \
    >/dev/null || fail "claim synthesized satisfied ${output##*/}"
done < <(/usr/bin/find "$tmp" -type f -name '*.out' -print)
pass 'no claim-only path can synthesize satisfied'

run_setup_controls

forged_duty="$tmp/forged-duty.json"
"$jq_bin" -S -c '.body.reason_ids=["forged"] | .body.verdict="violated"' \
  "$duty" >"$forged_duty"
forged_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$forged_duty" "$claim" >"$tmp/forged.out" \
  2>"$tmp/forged.err" || forged_status=$?
[ "$forged_status" -ne 0 ] && [ ! -s "$tmp/forged.out" ] &&
  [ "$(/bin/cat "$tmp/forged.err")" = E_DUTY ] || fail 'forged duty rejection'
pass 'forged duty is rejected'

noncanonical="$tmp/noncanonical.json"
"$jq_bin" . "$claim" >"$noncanonical"
canonical_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$noncanonical" >"$tmp/noncanonical.out" \
  2>"$tmp/noncanonical.err" || canonical_status=$?
[ "$canonical_status" -ne 0 ] && [ ! -s "$tmp/noncanonical.out" ] &&
  [ "$(/bin/cat "$tmp/noncanonical.err")" = E_CANONICAL ] ||
  fail 'noncanonical rejection'
pass 'noncanonical input is rejected'

malformed_json="$tmp/malformed.json"
/usr/bin/printf '{' >"$malformed_json"
[ "$(/usr/bin/wc -c <"$malformed_json" | /usr/bin/tr -d ' ')" -eq 1 ] &&
  [ "$(/usr/bin/od -An -tx1 "$malformed_json" | /usr/bin/tr -d ' \n')" = 7b ] ||
  fail 'malformed JSON fixture bytes'
parse_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$malformed_json" >"$tmp/parse.out" \
  2>"$tmp/parse.err" || parse_status=$?
[ "$parse_status" -ne 0 ] && [ ! -s "$tmp/parse.out" ] &&
  [ "$(/bin/cat "$tmp/parse.err")" = E_PARSE ] || fail 'malformed JSON rejection'
pass 'malformed JSON is rejected'

oversize="$tmp/oversize.json"
/bin/dd if=/dev/zero of="$oversize" bs=1048577 count=1 2>/dev/null
oversize_scratch="$tmp/oversize-scratch"
/bin/mkdir "$oversize_scratch"
oversize_status=0
TMPDIR="$oversize_scratch" PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$duty" "$oversize" \
  >"$tmp/oversize.out" 2>"$tmp/oversize.err" || oversize_status=$?
[ "$oversize_status" -ne 0 ] && [ ! -s "$tmp/oversize.out" ] &&
  [ "$(/bin/cat "$tmp/oversize.err")" = E_LIMIT ] &&
  [ -z "$(/usr/bin/find "$oversize_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'oversize input bound'
pass 'oversize input stops at the one-megabyte boundary'

swap_claim="$tmp/swap-claim.json"
swap_backup="$tmp/swap-claim.backup"
swap_replacement="$tmp/swap-claim.replacement"
swap_target="$tmp/synthetic-sensitive.json"
/bin/cp "$claim" "$swap_claim"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' >"$swap_target"
swap_scratch="$tmp/swap-scratch"
/bin/mkdir "$swap_scratch"
coordinate_input_setup path-swap "$swap_scratch" "$swap_claim"
/bin/mv "$swap_claim" "$swap_backup"
/bin/cp "$swap_target" "$swap_claim"
if [ -L "$swap_claim" ] || ! /usr/bin/cmp -s "$swap_target" "$swap_claim"; then
  fail 'path-swap replacement'
fi
resume_and_wait_input_race path-swap
/bin/mv "$swap_claim" "$swap_replacement"
/bin/mv "$swap_backup" "$swap_claim"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/path-swap.out" ] ||
   [ "$(/bin/cat "$tmp/path-swap.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$claim" "$swap_claim" ||
   ! /usr/bin/cmp -s "$swap_target" "$swap_replacement"; then
  fail 'transient path swap'
fi
[ -z "$(/usr/bin/find "$swap_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'path-swap scratch cleanup'
pass 'gated regular-file replacement is rejected before read and fully restored'

inplace_claim="$tmp/inplace-claim.json"
inplace_backup="$tmp/inplace-claim.backup"
/bin/cp "$claim" "$inplace_claim"
/bin/cp "$claim" "$inplace_backup"
inplace_scratch="$tmp/inplace-scratch"
/bin/mkdir "$inplace_scratch"
coordinate_input_setup same-inode "$inplace_scratch" "$inplace_claim"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' >"$inplace_claim"
if /usr/bin/cmp -s "$inplace_backup" "$inplace_claim"; then
  fail 'same-inode mutation did not change bytes'
fi
resume_and_wait_input_race same-inode
/bin/cp "$inplace_backup" "$inplace_claim"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/same-inode.out" ] ||
   [ "$(/bin/cat "$tmp/same-inode.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$inplace_backup" "$inplace_claim"; then
  fail 'same-inode content replacement'
fi
[ -z "$(/usr/bin/find "$inplace_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'same-inode scratch cleanup'
pass 'gated same-inode mutation is rejected before read and fully restored'

parent_swap_dir="$tmp/parent-swap"
parent_swap_backup="$tmp/parent-swap.original"
parent_swap_replacement="$tmp/parent-swap.replacement"
/bin/mkdir "$parent_swap_dir"
/bin/cp "$claim" "$parent_swap_dir/claim.json"
parent_swap_scratch="$tmp/parent-swap-scratch"
/bin/mkdir "$parent_swap_scratch"
coordinate_input_setup parent-swap "$parent_swap_scratch" "$parent_swap_dir/claim.json"
/bin/mv "$parent_swap_dir" "$parent_swap_backup"
/bin/mkdir "$parent_swap_dir"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' \
  >"$parent_swap_dir/claim.json"
resume_and_wait_input_race parent-swap
/bin/mv "$parent_swap_dir" "$parent_swap_replacement"
/bin/mv "$parent_swap_backup" "$parent_swap_dir"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/parent-swap.out" ] ||
   [ "$(/bin/cat "$tmp/parent-swap.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$claim" "$parent_swap_dir/claim.json" ||
   ! /usr/bin/grep -Fq synthetic_secret "$parent_swap_replacement/claim.json"; then
  fail 'transient parent replacement'
fi
[ -z "$(/usr/bin/find "$parent_swap_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'parent-swap scratch cleanup'
pass 'gated parent-directory replacement is rejected before read and fully restored'

link="$tmp/claim-link.json"
/bin/ln -s "$claim" "$link"
link_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$link" >"$tmp/link.out" \
  2>"$tmp/link.err" || link_status=$?
[ "$link_status" -ne 0 ] && [ ! -s "$tmp/link.out" ] &&
  [ "$(/bin/cat "$tmp/link.err")" = E_RUNTIME ] || fail 'symlink rejection'
pass 'symlink input is rejected'

fake_bin="$tmp/fake-bin"
/bin/mkdir "$fake_bin"
/usr/bin/printf '%s\n' '#!/bin/bash' 'printf "jq-1.6\n"' >"$fake_bin/jq"
/bin/chmod 0555 "$fake_bin/jq"
fake_status=0
PATH="$fake_bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$claim" >"$tmp/fake.out" \
  2>"$tmp/fake.err" || fake_status=$?
[ "$fake_status" -ne 0 ] && [ ! -s "$tmp/fake.out" ] &&
  [ "$(/bin/cat "$tmp/fake.err")" = E_RUNTIME ] || fail 'jq digest rejection'
pass 'interpreter identity is pinned'

copy_runtime() {
  local destination=$1 copy_path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for copy_path in credential-policy.json credential-policy-decision.json \
    credential-policy.jq evaluate-credential-policy.sh duty-separation-policy.json \
    duty-separation-decision.json duty-separation.jq evaluate-duty.sh validate.sh \
    policy-set.jq; do
    /bin/cp "$root/control/v1/$copy_path" "$destination/control/v1/$copy_path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}

startup_runtime="$tmp/startup-runtime"
copy_runtime "$startup_runtime"
startup_instrumented="$tmp/startup-evaluator.instrumented"
/usr/bin/awk '
  {print}
  $0 == "  2>/dev/null) || emit_error E_RUNTIME" {
    print "/bin/kill -TERM $$"
    injected += 1
  }
  END {if (injected != 1) exit 2}
' "$startup_runtime/control/v1/evaluate-credential-policy.sh" >"$startup_instrumented" ||
  fail 'startup cleanup instrumentation'
/bin/chmod 0500 "$startup_instrumented"
/bin/mv "$startup_instrumented" \
  "$startup_runtime/control/v1/evaluate-credential-policy.sh"
startup_cleanup_scratch="$tmp/startup-cleanup-scratch"
/bin/mkdir "$startup_cleanup_scratch"
startup_cleanup_status=0
TMPDIR="$startup_cleanup_scratch" PATH="$bin:/usr/bin:/bin" \
  "$startup_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
  >"$tmp/startup-cleanup.out" 2>"$tmp/startup-cleanup.err" ||
  startup_cleanup_status=$?
if [ "$startup_cleanup_status" -ne 143 ] || [ -s "$tmp/startup-cleanup.out" ] ||
   [ -s "$tmp/startup-cleanup.err" ] ||
   [ -n "$(/usr/bin/find "$startup_cleanup_scratch" -mindepth 1 -print -quit)" ]; then
  fail 'startup signal cleanup'
fi
pass 'startup signal keeps cleanup armed before physicalization'

binding_runtime="$tmp/binding-runtime"
copy_runtime "$binding_runtime"
binding_scratch="$tmp/binding-scratch"
/bin/mkdir "$binding_scratch"
(
  binding_status=0
  TMPDIR="$binding_scratch" PATH="$bin:/usr/bin:/bin" \
    "$binding_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
    >"$tmp/binding.out" 2>"$tmp/binding.err" || binding_status=$?
  /usr/bin/printf '%s\n' "$binding_status" >"$tmp/binding.status"
) &
binding_pid=$!
binding_marker=
binding_attempt=0
while [ -z "$binding_marker" ] && /bin/kill -0 "$binding_pid" 2>/dev/null &&
  [ "$binding_attempt" -lt 1000 ]; do
  binding_marker=$(/usr/bin/find "$binding_scratch" -type f \
    -name runtime-bindings-ready -print -quit 2>/dev/null)
  [ -n "$binding_marker" ] || /bin/sleep 0.01
  binding_attempt=$((binding_attempt + 1))
done
[ -n "$binding_marker" ] || fail 'runtime binding marker'
/usr/bin/printf '\n' >>"$binding_runtime/control/v1/duty-separation.jq"
wait "$binding_pid"
[ "$(/bin/cat "$tmp/binding.status")" -ne 0 ] && [ ! -s "$tmp/binding.out" ] &&
  [ "$(/bin/cat "$tmp/binding.err")" = E_RELATION ] ||
  fail 'decision-bound runtime mutation'
[ -z "$(/usr/bin/find "$binding_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'runtime binding scratch cleanup'
pass 'decision-bound runtime mutation closes before execution'

race_runtime="$tmp/race-runtime"
copy_runtime "$race_runtime"
race_scratch="$tmp/race-scratch"
/bin/mkdir "$race_scratch"
(
  race_status=0
  TMPDIR="$race_scratch" PATH="$bin:/usr/bin:/bin" \
    "$race_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
    >"$tmp/race.out" 2>"$tmp/race.err" || race_status=$?
  /usr/bin/printf '%s\n' "$race_status" >"$tmp/race.status"
) &
race_pid=$!
race_marker=
race_attempt=0
while [ -z "$race_marker" ] && /bin/kill -0 "$race_pid" 2>/dev/null &&
  [ "$race_attempt" -lt 1000 ]; do
  race_marker=$(/usr/bin/find "$race_scratch" -type f -name duty-ready -print -quit \
    2>/dev/null)
  [ -n "$race_marker" ] || /bin/sleep 0.01
  race_attempt=$((race_attempt + 1))
done
[ -n "$race_marker" ] || fail 'TOCTOU marker'
/usr/bin/printf '\n' >>"$race_runtime/control/v1/credential-policy.jq"
wait "$race_pid"
[ "$(/bin/cat "$tmp/race.status")" -ne 0 ] && [ ! -s "$tmp/race.out" ] &&
  [ "$(/bin/cat "$tmp/race.err")" = E_RELATION ] || fail 'TOCTOU closure'
[ -z "$(/usr/bin/find "$race_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'TOCTOU scratch cleanup'
pass 'TOCTOU mutation closes and cleans scratch'

signal_runtime="$tmp/signal-runtime"
copy_runtime "$signal_runtime"
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
start_input_race signal "$signal_scratch" "$claim" \
  "$signal_runtime/control/v1/evaluate-credential-policy.sh"
signal_owned_child_group signal "$signal_scratch"
wait_evaluator_group signal
if [ "$INPUT_RACE_STATUS" -ne 143 ] || [ -s "$tmp/signal.out" ] ||
   [ -s "$tmp/signal.err" ] || /bin/kill -0 "$SIGNAL_CHILD_PID" 2>/dev/null ||
   /bin/kill -0 "$SIGNAL_DESCENDANT_PID" 2>/dev/null ||
   group_alive "$SIGNAL_CHILD_PGID" ||
   [ -n "$(/usr/bin/find "$signal_scratch" -mindepth 1 -print -quit)" ]; then
  fail 'signal cleanup'
fi
SIGNAL_CHILD_PID=
SIGNAL_CHILD_PGID=
SIGNAL_DESCENDANT_PID=
pass 'owned live child group is signaled, reaped, and scratch-cleaned'

output_swap_scratch="$tmp/output-swap-scratch"
/bin/mkdir "$output_swap_scratch"
start_input_race output-swap "$output_swap_scratch" "$claim"
stop_at_owned_marker output-swap "$output_swap_scratch" final-cleanup-pending \
  final-output-validated
output_swap_path="${STOPPED_MARKER_PATH%/*}/output.json"
output_swap_backup="$tmp/output-swap.backup"
/bin/mv "$output_swap_path" "$output_swap_backup"
/bin/cp "$output_swap_backup" "$output_swap_path"
resume_and_wait_input_race output-swap
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/output-swap.out" ] ||
   [ "$(/bin/cat "$tmp/output-swap.err")" != E_RUNTIME ] ||
   [ -n "$(/usr/bin/find "$output_swap_scratch" -mindepth 1 -print -quit)" ]; then
  fail 'final identical-byte output replacement'
fi
pass 'final output replacement is identity-rejected before emission'

output_symlink_scratch="$tmp/output-symlink-scratch"
/bin/mkdir "$output_symlink_scratch"
start_input_race output-symlink "$output_symlink_scratch" "$claim"
stop_at_owned_marker output-symlink "$output_symlink_scratch" final-cleanup-pending \
  final-output-validated
output_symlink_path="${STOPPED_MARKER_PATH%/*}/output.json"
output_symlink_backup="$tmp/output-symlink.backup"
/bin/mv "$output_symlink_path" "$output_symlink_backup"
/bin/ln -s "$output_symlink_backup" "$output_symlink_path"
resume_and_wait_input_race output-symlink
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/output-symlink.out" ] ||
   [ "$(/bin/cat "$tmp/output-symlink.err")" != E_RUNTIME ] ||
   [ -n "$(/usr/bin/find "$output_symlink_scratch" -mindepth 1 -print -quit)" ]; then
  fail 'final symlink output replacement'
fi
pass 'final output symlink is rejected before emission'

cleanup_failure_scratch="$tmp/cleanup-failure-scratch"
/bin/mkdir "$cleanup_failure_scratch"
start_input_race cleanup-failure "$cleanup_failure_scratch" "$claim"
stop_at_owned_marker cleanup-failure "$cleanup_failure_scratch" final-cleanup-pending \
  final-output-validated
/bin/chmod 0500 "$cleanup_failure_scratch"
resume_and_wait_input_race cleanup-failure
cleanup_failure_residual=$(/usr/bin/find "$cleanup_failure_scratch" -mindepth 1 \
  -print -quit 2>/dev/null)
/bin/chmod 0700 "$cleanup_failure_scratch"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/cleanup-failure.out" ] ||
   [ "$(/bin/cat "$tmp/cleanup-failure.err")" != E_RUNTIME ] ||
   [ -z "$cleanup_failure_residual" ]; then
  fail 'forced cleanup failure result'
fi
/bin/rm -rf -- "$cleanup_failure_scratch"
pass 'cleanup failure stays non-success and emits no output'

final_cleanup_scratch="$tmp/final-cleanup-scratch"
/bin/mkdir "$final_cleanup_scratch"
start_input_race final-cleanup "$final_cleanup_scratch" "$claim"
stop_at_owned_marker final-cleanup "$final_cleanup_scratch" final-cleanup-pending \
  final-output-validated
/bin/kill -TERM "$INPUT_RACE_PID" || fail 'final cleanup signal delivery'
/bin/kill -CONT -- "-$INPUT_RACE_PGID" || fail 'final cleanup resume'
wait_evaluator_group final-cleanup
if [ "$INPUT_RACE_STATUS" -ne 143 ] || [ -s "$tmp/final-cleanup.out" ] ||
   [ -s "$tmp/final-cleanup.err" ] ||
   [ -n "$(/usr/bin/find "$final_cleanup_scratch" -mindepth 1 -print -quit)" ]; then
  fail 'final signal cleanup'
fi
pass 'final signal keeps cleanup armed and removes scratch before output'

/usr/bin/printf 'control credential policy: %s passed\n' "$passes"
