#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in);
    @stat && S_ISREG($stat[2]) or exit 40;
    $stat[7] <= $limit or exit 42;
    sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,oct($mode))
      or exit 40;
    my $total=0;
    while (1) {
      my $read=sysread($in,my $buffer,65536);
      defined($read) or exit 40;
      last if $read == 0;
      $total += $read;
      $total <= $limit or exit 42;
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($out,$buffer,$read-$offset,$offset);
        defined($written) && $written > 0 or exit 40;
        $offset += $written;
      }
    }
    close($in) or exit 40;
    close($out) or exit 40;
    chmod(oct($mode),$target) == 1 or exit 40;
  ' "$1" "$2" "$3" "$4"
}

snapshot_expected() {
  local expected=$1 source=$2 target=$3 mode=$4 status=0
  snapshot_file "$source" "$target" 16777216 "$mode" || status=$?
  [ "$status" -eq 0 ] && [ "$(sha256_path "$target")" = "$expected" ]
}

# run SEED-SET.json OBSERVED_AT
# dashboard OBSERVED_AT SEED-SET.json RUN-RESULT.json [SEED-SET.json RUN-RESULT.json]...
mode=${1:-}
case "$mode" in
  run)
    [ "$#" -eq 3 ] || emit_error E_USAGE
    input=$2
    observed_at=$3
    pair_files=()
    ;;
  dashboard)
    [ "$#" -ge 4 ] && [ "$#" -le 34 ] && [ $(( ($# - 2) % 2 )) -eq 0 ] || emit_error E_USAGE
    observed_at=$2
    input=''
    shift 2
    pair_files=("$@")
    ;;
  *) emit_error E_USAGE ;;
esac
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$source_dir/${self##*/}"
[ "$self" = "$source_dir/evals-launcher.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/evals/v1" ] || emit_error E_RUNTIME
if [ "$mode" = run ]; then
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
else
  for pair_file in "${pair_files[@]}"; do
    [ -f "$pair_file" ] && [ ! -L "$pair_file" ] || emit_error E_RUNTIME
  done
fi

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64)
    host_os=linux; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  Darwin:x86_64)
    host_os=darwin; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Darwin:arm64)
    host_os=darwin; host_arch=arm64; jq_arch=x86_64; execution_mode=rosetta
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  *) emit_error E_RUNTIME ;;
esac

jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" "/usr/bin/jq"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha256_path "$candidate")" = "$jq_sha" ]; then
    jq_source=$candidate
    break
  fi
done
[ -n "$jq_source" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
runtime="$scratch/runtime"
/bin/mkdir -m 0700 "$runtime" "$runtime/bin" "$runtime/core" "$runtime/core/v2" \
  "$runtime/core/v2/generations" "$runtime/scripts" "$runtime/orchestrator" \
  "$runtime/orchestrator/v1" "$runtime/control" "$runtime/control/v1" "$runtime/adapters" \
  "$runtime/adapters/codex-native-reviewer" "$runtime/adapters/codex-native-reviewer/v1" \
  "$runtime/adapters/github-actions-ci" "$runtime/adapters/github-actions-ci/v1" \
  "$runtime/adapters/github-forge" "$runtime/adapters/github-forge/v1" \
  "$runtime/adapters/gitlab-forge" "$runtime/adapters/gitlab-forge/v1" \
  "$runtime/adapters/codex-cli-producer" "$runtime/adapters/codex-cli-producer/v1" "$scratch/work" ||
  emit_error E_RUNTIME
generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
generation_runtime="$runtime/core/v2/generations/$generation"
/bin/mkdir -m 0700 "$generation_runtime" "$generation_runtime/modules" ||
  emit_error E_RUNTIME

program_sha=25f89c2f6cfff82388cad0bc400ba971de665cd608d1009fecc33b15f7d3d6fb
catalog_sha=0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac
driver_sha=1ceef4f3e3b0ce4459232b4c2ce0751e7fef7eec2f8bd592c5d2b595bb94f5b0
snapshot_file "$source_dir/run-evals.sh" "$runtime/bootstrap.sh" 1048576 0400 ||
  emit_error E_RUNTIME
bootstrap_sha=$(sha256_path "$runtime/bootstrap.sh") || emit_error E_RUNTIME
snapshot_file "$self" "$runtime/launcher.sh" 1048576 0400 || emit_error E_RUNTIME
launcher_sha=$(sha256_path "$runtime/launcher.sh") || emit_error E_RUNTIME
snapshot_expected "$driver_sha" "$source_dir/evals-driver.sh" "$runtime/driver.sh" 0400 ||
  emit_error E_STALE
snapshot_expected "$program_sha" "$source_dir/evals.jq" "$runtime/program.jq" 0400 ||
  emit_error E_STALE
snapshot_expected "$catalog_sha" "$source_dir/eval-catalog.json" "$runtime/catalog.json" 0400 ||
  emit_error E_STALE
snapshot_expected 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
  "$repo/core/v2/generation-registry.json" \
  "$runtime/core/v2/generation-registry.json" 0400 || emit_error E_STALE
snapshot_expected 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
  "$repo/core/v2/generations/$generation/contracts.jq" \
  "$generation_runtime/contracts.jq" 0400 || emit_error E_STALE
snapshot_expected dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
  "$repo/core/v2/generations/$generation/core-ingress.sh" \
  "$generation_runtime/core-ingress.sh" 0400 || emit_error E_STALE
for member in \
  'profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207' \
  'result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281' \
  'result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46' \
  'schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade' \
  'stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" \
    "$repo/core/v2/generations/$generation/modules/$name" \
    "$generation_runtime/modules/$name" 0400 || emit_error E_STALE
done
snapshot_expected b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  "$repo/scripts/core-contract.sh" "$runtime/scripts/core-contract.sh" 0400 ||
  emit_error E_STALE
# The inactive state scanner, replayed for the events family from inside the
# private runtime. It reads its core from this runtime's mirror, never the repo.
for member in \
  'reconciliation-plan.jq 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4' \
  'scan-state.sh 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5' \
  'state-scanner-driver.sh 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b' \
  'state-scanner-launcher.sh 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb' \
  'state-scanner.jq 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/orchestrator/v1/$name" \
    "$runtime/orchestrator/v1/$name" 0400 || emit_error E_STALE
done
# The inactive control evaluators replayed here: sandbox policy for the boundaries
# family; risk gates (with the duty-separation evaluator it regenerates) for the
# approval family; that same duty-separation evaluator on its own for the actor
# and re-run identity family. They read only this runtime.
for member in \
  'duty-separation-decision.json 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99' \
  'duty-separation-policy.json b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9' \
  'duty-separation.jq b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c' \
  'evaluate-duty.sh 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa' \
  'evaluate-risk-gates.sh 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8' \
  'evaluate-sandbox.sh 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb' \
  'policy-set.jq 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58' \
  'risk-gates-decision.json 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5' \
  'risk-gates-policy.json 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e' \
  'risk-gates.jq d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff' \
  'sandbox-decision.json c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd' \
  'sandbox-policy.json 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e' \
  'sandbox.jq 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3' \
  'validate.sh cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/control/v1/$name" \
    "$runtime/control/v1/$name" 0400 || emit_error E_STALE
done
# The inactive provider-snapshot normalizers, replayed for the adapter family.
for member in \
  'codex-cli-producer dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25' \
  'gitlab-forge b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713' \
  'codex-native-reviewer 7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603' \
  'github-actions-ci 690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7' \
  'github-forge b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/adapters/$name/v1/normalize.jq" \
    "$runtime/adapters/$name/v1/normalize.jq" 0400 || emit_error E_STALE
done
snapshot_expected "$jq_sha" "$jq_source" "$runtime/bin/jq" 0500 || emit_error E_RUNTIME
bash_sha=$(sha256_path /bin/bash) || emit_error E_RUNTIME
snapshot_input() {
  local status=0
  snapshot_file "$1" "$2" 1048576 0400 || status=$?
  [ "$status" -eq 42 ] && emit_error E_LIMIT
  [ "$status" -eq 0 ] || emit_error E_RUNTIME
}
if [ "$mode" = run ]; then
  snapshot_input "$input" "$scratch/input.json"
  driver_input="$scratch/input.json"
  input_document="$scratch/input.json"
else
  # Each (seed set, run result) pair is snapshotted once; a manifest of their
  # digests is the single input document the driver binds to.
  /bin/mkdir -m 0700 "$scratch/inputs" || emit_error E_RUNTIME
  pair_count=$(( ${#pair_files[@]} / 2 ))
  manifest_entries=''
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    snapshot_input "${pair_files[$((j * 2))]}" "$scratch/inputs/seed-$j.json"
    snapshot_input "${pair_files[$((j * 2 + 1))]}" "$scratch/inputs/result-$j.json"
    manifest_entries="$manifest_entries$(/usr/bin/printf '{"result_sha256":"%s","seed_sha256":"%s"}' \
      "$(sha256_path "$scratch/inputs/result-$j.json")" \
      "$(sha256_path "$scratch/inputs/seed-$j.json")")"
    j=$((j + 1))
    [ "$j" -eq "$pair_count" ] || manifest_entries="$manifest_entries,"
  done
  /usr/bin/printf '[%s]' "$manifest_entries" | "$runtime/bin/jq" -S -c . \
    > "$scratch/inputs/manifest.json" 2>/dev/null || emit_error E_RUNTIME
  /bin/chmod 0400 "$scratch/inputs/manifest.json" || emit_error E_RUNTIME
  driver_input="$scratch/inputs"
  input_document="$scratch/inputs/manifest.json"
fi
seed_sha=$(sha256_path "$input_document") || emit_error E_RUNTIME

"$runtime/bin/jq" -S -c -n \
  --arg bootstrap_sha "$bootstrap_sha" --arg launcher_sha "$launcher_sha" \
  --arg driver_sha "$driver_sha" --arg program_sha "$program_sha" \
  --arg catalog_sha "$catalog_sha" \
  --arg jq_sha "$jq_sha" --arg bash_sha "$bash_sha" \
  --arg host_os "$host_os" --arg host_arch "$host_arch" \
  --arg jq_arch "$jq_arch" --arg execution_mode "$execution_mode" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  {
    schema_version:1,kind:"eval_framework_evaluator",id:"evals.framework.v1",
    body:{
      core_contract:{
        generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
        package_ref:ref("core-contract-package.v2";
          "application/vnd.ystack.core-contract+json";
          "eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"),
        semantic_identity:"core.contracts.v2"
      },
      core_closure:[
        {path:"core/v2/generation-registry.json",sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
        {path:"scripts/core-contract.sh",sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
      ],
      orchestrator_closure:[
        {path:"orchestrator/v1/reconciliation-plan.jq",sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
        {path:"orchestrator/v1/scan-state.sh",sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
        {path:"orchestrator/v1/state-scanner-driver.sh",sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
        {path:"orchestrator/v1/state-scanner-launcher.sh",sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
        {path:"orchestrator/v1/state-scanner.jq",sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
      ],
      adapter_closure:[
        {path:"adapters/codex-cli-producer/v1/normalize.jq",sha256:"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25"},
        {path:"adapters/codex-native-reviewer/v1/normalize.jq",sha256:"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603"},
        {path:"adapters/github-actions-ci/v1/normalize.jq",sha256:"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7"},
        {path:"adapters/github-forge/v1/normalize.jq",sha256:"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be"},
        {path:"adapters/gitlab-forge/v1/normalize.jq",sha256:"b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713"}
      ],
      control_closure:[
        {path:"control/v1/duty-separation-decision.json",sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
        {path:"control/v1/duty-separation-policy.json",sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
        {path:"control/v1/duty-separation.jq",sha256:"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
        {path:"control/v1/evaluate-duty.sh",sha256:"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
        {path:"control/v1/evaluate-risk-gates.sh",sha256:"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
        {path:"control/v1/evaluate-sandbox.sh",sha256:"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
        {path:"control/v1/policy-set.jq",sha256:"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
        {path:"control/v1/risk-gates-decision.json",sha256:"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
        {path:"control/v1/risk-gates-policy.json",sha256:"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
        {path:"control/v1/risk-gates.jq",sha256:"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
        {path:"control/v1/sandbox-decision.json",sha256:"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
        {path:"control/v1/sandbox-policy.json",sha256:"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
        {path:"control/v1/sandbox.jq",sha256:"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
        {path:"control/v1/validate.sh",sha256:"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"}
      ],
      bootstrap_ref:ref("evals-framework-bootstrap.v1";"text/x-shellscript";$bootstrap_sha),
      launcher_ref:ref("evals-framework-launcher.v1";"text/x-shellscript";$launcher_sha),
      driver_ref:ref("evals-framework-driver.v1";"text/x-shellscript";$driver_sha),
      program_ref:ref("evals-framework-program.v1";"text/x-jq";$program_sha),
      catalog_ref:ref("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json";$catalog_sha),
      runtime:{
        host_os:$host_os,host_architecture:$host_arch,jq_architecture:$jq_arch,
        execution_mode:$execution_mode,
        jq_ref:ref("jq-runtime.v1";"application/x-executable";$jq_sha),
        shell_ref:ref("bash-runtime";"application/x-executable";$bash_sha)
      }
    }
  }
' > "$runtime/evaluator.json" 2>/dev/null || emit_error E_RUNTIME
evaluator_sha=$(sha256_path "$runtime/evaluator.json") || emit_error E_RUNTIME

output="$scratch/output.json"
error="$scratch/error"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scratch/work" \
  /bin/bash "$runtime/driver.sh" "$mode" "$runtime" "$driver_input" \
  "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" "$observed_at" \
  </dev/null >"$output" 2>"$error"
status=$?
if [ "$status" -ne 0 ]; then
  [ ! -s "$output" ] || emit_error E_RUNTIME
  driver_error=$(/bin/cat "$error" 2>/dev/null) || emit_error E_RUNTIME
  case "$driver_error" in
    E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      emit_error "$driver_error"
      ;;
    *) emit_error E_RUNTIME ;;
  esac
fi
[ ! -s "$error" ] || emit_error E_RUNTIME

# Independent re-validation of the delivered document against the exact same
# private program and core, after the driver has exited.
# program_check OPERATION EVALUATOR EVALUATOR_SHA SEED_SHA SEEDS OBSERVATIONS CANDIDATE RESULTS RESULT_SHAS
# check_observed_at names the time the candidate was built at; a run result is
# rebuilt at its own recorded time, the dashboard at this invocation's time.
check_observed_at=$observed_at
program_check() {
  [ "$("$runtime/bin/jq" -S -c -n -L "$generation_runtime/modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
    --arg catalog_sha256 "$catalog_sha" --arg evaluator_sha256 "$3" \
    --arg seed_set_sha256 "$4" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 \
    --arg planner_sha256 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 \
    --arg sandbox_sha256 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb \
    --argjson normalizer_shas '{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713"}' \
    --arg risk_gates_sha256 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 \
    --arg duty_sha256 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa \
    --arg observed_at "$check_observed_at" \
    --slurpfile catalog_docs "$runtime/catalog.json" \
    --slurpfile seed_set_docs "$5" \
    --slurpfile observation_docs "$6" \
    --slurpfile evaluator_docs "$2" \
    --slurpfile candidate_docs "$7" \
    --slurpfile result_docs "$8" --argjson result_shas "$9" \
    -f "$runtime/program.jq" 2>/dev/null)" = true ]
}
if [ "$mode" = run ]; then
  program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$scratch/input.json" "$scratch/work/observations.json" "$output" \
    "$scratch/work/observations.json" '[]' || emit_error E_RUNTIME
else
  # Every pair is re-validated against the driver's replay, then the dashboard itself.
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    check_observed_at=$("$runtime/bin/jq" -r '.body.observed_at' "$scratch/inputs/result-$j.json") ||
      emit_error E_RUNTIME
    # The driver replayed this seed set into pair-$j; re-validate the supplied
    # result against that fresh observation set and this runtime's evaluator.
    [ -f "$scratch/work/pair-$j/observations.json" ] || emit_error E_RUNTIME
    program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" \
      "$(sha256_path "$scratch/inputs/seed-$j.json")" "$scratch/inputs/seed-$j.json" \
      "$scratch/work/pair-$j/observations.json" "$scratch/inputs/result-$j.json" \
      "$scratch/work/pair-$j/observations.json" '[]' || emit_error E_RELATION
    j=$((j + 1))
  done
  check_observed_at=$observed_at
  program_check validate-dashboard "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$scratch/work/seeds.jsonl" "$scratch/work/pair-0/observations.json" "$output" \
    "$scratch/work/results.jsonl" \
    "$("$runtime/bin/jq" -c 'map(.result_sha256)' "$scratch/inputs/manifest.json")" ||
    emit_error E_RUNTIME
fi
"$runtime/bin/jq" -S -c . "$output" > "$scratch/output.canonical" 2>/dev/null ||
  emit_error E_CANONICAL
/usr/bin/cmp -s "$output" "$scratch/output.canonical" || emit_error E_CANONICAL
[ "$(sha256_path "$runtime/bootstrap.sh")" = "$bootstrap_sha" ] &&
[ "$(sha256_path "$runtime/launcher.sh")" = "$launcher_sha" ] &&
[ "$(sha256_path "$runtime/adapters/codex-cli-producer/v1/normalize.jq")" = \
    dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25 ] &&
[ "$(sha256_path "$runtime/adapters/gitlab-forge/v1/normalize.jq")" = \
    b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713 ] &&
[ "$(sha256_path "$runtime/adapters/codex-native-reviewer/v1/normalize.jq")" = \
    7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603 ] &&
[ "$(sha256_path "$runtime/adapters/github-actions-ci/v1/normalize.jq")" = \
    690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7 ] &&
[ "$(sha256_path "$runtime/adapters/github-forge/v1/normalize.jq")" = \
    b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-sandbox.sh")" = \
    8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-risk-gates.sh")" = \
    0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-policy.json")" = \
    3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-decision.json")" = \
    8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates.jq")" = \
    d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-policy.json")" = \
    b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-decision.json")" = \
    4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation.jq")" = \
    b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-duty.sh")" = \
    146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa ] &&
[ "$(sha256_path "$runtime/control/v1/policy-set.jq")" = \
    2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-decision.json")" = \
    c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-policy.json")" = \
    4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox.jq")" = \
    83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 ] &&
[ "$(sha256_path "$runtime/control/v1/validate.sh")" = \
    cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/reconciliation-plan.jq")" = \
    03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/scan-state.sh")" = \
    556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-driver.sh")" = \
    5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-launcher.sh")" = \
    9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner.jq")" = \
    722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae ] &&
[ "$(sha256_path "$runtime/driver.sh")" = "$driver_sha" ] &&
[ "$(sha256_path "$runtime/program.jq")" = "$program_sha" ] &&
[ "$(sha256_path "$runtime/catalog.json")" = "$catalog_sha" ] &&
[ "$(sha256_path "$runtime/bin/jq")" = "$jq_sha" ] &&
[ "$(sha256_path /bin/bash)" = "$bash_sha" ] &&
[ "$(sha256_path "$input_document")" = "$seed_sha" ] &&
[ "$(sha256_path "$runtime/evaluator.json")" = "$evaluator_sha" ] ||
  emit_error E_RUNTIME
/bin/cat "$output" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
