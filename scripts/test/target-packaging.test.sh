#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
builder="$root/packaging/v1/build-release.sh"
installer="$root/packaging/v1/install.sh"
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-target-packaging.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
trap '/bin/chmod -R u+w "$tmp" >/dev/null 2>&1 || :; /bin/rm -rf -- "$tmp"' EXIT

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) asset='jq-linux64'; asset_sha='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44' ;;
  Darwin:x86_64|Darwin:arm64) asset='jq-osx-amd64'; asset_sha='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef' ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac
# This suite may run before any other, so it fills the shared jq 1.6 cache itself.
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$asset_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$asset" -o "$download"
  [ "$(sha_file "$download")" = "$asset_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq="$bin/jq"
[ "$("$jq" --version)" = jq-1.6 ] || fail 'pinned jq 1.6 is required'
export PATH="$bin:/usr/bin:/bin"

for shipped in "$builder" "$installer" "$root/packaging/v1/packaging.jq"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing $shipped"
done
[ -x "$builder" ] && [ -x "$installer" ] || fail 'drivers must be executable'

commit=$(/usr/bin/git -C "$root" rev-parse HEAD)
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'core generation'

manifest="$tmp/release.json"
"$builder" build-release "$commit" profile.default.v1 profile.alternative.v1 >"$manifest"
"$builder" build-release "$commit" profile.default.v1 profile.alternative.v1 >"$tmp/release-again.json"
/usr/bin/cmp -s "$manifest" "$tmp/release-again.json" || fail 'release build is not deterministic'
"$jq" -S -c . "$manifest" >"$tmp/release.canonical" || fail 'release parse'
/usr/bin/cmp -s "$manifest" "$tmp/release.canonical" || fail 'release bytes are not canonical'
"$jq" -e --arg commit "$commit" --arg generation "$generation" '
  .schema_version == 1 and .kind == "release_manifest" and
  (.id | test("\\Arelease\\.[0-9a-f]{64}\\z")) and
  .body.activation == "none" and .body.authority == "none" and
  .body.qualification == {state: "unavailable"} and
  .body.source == {commit_id: $commit, hash_algorithm: "sha1", repository_id: "repo.ystack"} and
  .body.core_contract == {generation_id: $generation, schema_major: 2} and
  ([.body.profiles[].profile_id] == ["profile.alternative.v1","profile.default.v1"])
' "$manifest" >/dev/null || fail 'release manifest identity'
ok 'build-release emits one deterministic canonical release manifest at an exact commit'

while IFS=$'\t' read -r path mode object_id sha256; do
  case "$path" in
    profiles/*/v1/*|adapters/*/v1/*|"core/v2/generations/$generation/"*|scripts/core-contract.sh) ;;
    *) fail "packaged path outside the shipped product shapes: $path" ;;
  esac
  case "$path" in
    config/*|.claude/*|manager/*|work/*|.github/*|website/*|templates/*|routines/*|reviewer/*)
      fail "packaged path is personal or target-owned configuration: $path" ;;
  esac
  record=$(/usr/bin/git -C "$root" ls-tree --full-tree "$commit" -- "$path")
  [ "$record" = "$mode blob $object_id"$'\t'"$path" ] || fail "packaged object drifted: $path"
  /usr/bin/git -C "$root" cat-file blob "$object_id" >"$tmp/blob"
  [ "$(sha_file "$tmp/blob")" = "$sha256" ] || fail "packaged digest drifted: $path"
done < <("$jq" -r '.body.files[] | [.path,.mode,.object_id,.sha256] | @tsv' "$manifest")
ok 'every packaged file is an exact Git object at the release commit and nothing personal is packaged'

install_into() {
  local target=$1 profile_id=$2
  /bin/mkdir -p "$target"
  "$installer" install "$manifest" "$profile_id" "$target" >"$tmp/record-id"
}
default_target="$tmp/target-default"
alt_target="$tmp/target-alternative"
repeat_target="$tmp/target-repeat"
install_into "$default_target" profile.default.v1
install_into "$alt_target" profile.alternative.v1
install_into "$repeat_target" profile.default.v1

for installed in "$default_target" "$alt_target"; do
  contract="$installed/.ystack/scripts/core-contract.sh"
  [ -x "$contract" ] && [ ! -L "$contract" ] || fail 'installed contract validator is not runnable'
  profile=$(/usr/bin/find "$installed/.ystack/profiles" -name profile.json)
  "$contract" validate-document "$profile" || fail 'installed profile fails core validation'
  for manifest_file in "${profile%/*}"/manifests/*.json; do
    "$contract" validate-document "$manifest_file" ||
      fail "installed manifest fails core validation: $manifest_file"
  done
done
ok 'the installed trees validate with their own installed core-contract.sh'

"$jq" -e '.body.bindings[] | select(.role=="producer") |
  .manifest_ref.id == "adapter.claude-code-producer.v1"' \
  "$default_target/.ystack/profiles/default/v1/profile.json" >/dev/null ||
  fail 'default install producer'
"$jq" -e '.body.bindings[] | select(.role=="producer") |
  .manifest_ref.id == "adapter.codex-cli-producer.v1"' \
  "$alt_target/.ystack/profiles/alternative/v1/profile.json" >/dev/null ||
  fail 'alternative install producer'
[ ! -d "$default_target/.ystack/profiles/alternative" ] || fail 'default install leaked the alternative profile'
ok 'each install carries only the profile it was asked for'

tree_listing() {
  local installed=$1 file relative executable
  while IFS= read -r file; do
    relative=${file#"$installed/.ystack/"}
    if [ -x "$file" ]; then executable=x; else executable=-; fi
    /usr/bin/printf '%s %s %s\n' "$relative" "$executable" "$(sha_file "$file")"
  done < <(/usr/bin/find "$installed/.ystack" -type f | /usr/bin/sort)
}
tree_listing "$default_target" >"$tmp/listing-a"
tree_listing "$repeat_target" >"$tmp/listing-b"
/usr/bin/cmp -s "$tmp/listing-a" "$tmp/listing-b" || fail 'repeat install is not byte-identical'
ok 'a repeat install of the same release and profile is byte-identical'

manifest_sha=$(sha_file "$manifest")
release_id=$("$jq" -r '.id' "$manifest")
record="$default_target/.ystack/install-record.json"
"$jq" -S -c . "$record" >"$tmp/record.canonical"
/usr/bin/cmp -s "$record" "$tmp/record.canonical" || fail 'install record is not canonical'
"$jq" -e --arg release_id "$release_id" --arg manifest_sha "$manifest_sha" \
  --arg commit "$commit" '
  .schema_version == 1 and .kind == "install_record" and
  .body.activation == "none" and .body.authority == "none" and
  .body.qualification == {state: "unavailable"} and
  .body.profile_id == "profile.default.v1" and
  .body.north_star == {owner: "target", path: ".ystack/north-star.md",
    sha256: .body.north_star.sha256, state: "placeholder-unset"} and
  .body.release_ref == {content_id: $release_id,
    media_type: "application/vnd.ystack.release-manifest+json", sha256: $manifest_sha} and
  .body.source.commit_id == $commit and (.body.installed | length) == 24
' "$record" >/dev/null || fail 'install record identity'
while IFS=$'\t' read -r path sha256; do
  [ "$(sha_file "$default_target/.ystack/$path")" = "$sha256" ] ||
    fail "install record digest does not match the installed file: $path"
done < <("$jq" -r '.body.installed[] | [.path,.sha256] | @tsv' "$record")
ok 'the install record binds the release, every installed digest, and records no authority'

north_star="$default_target/.ystack/north-star.md"
[ "$(sha_file "$north_star")" = "$("$jq" -r '.body.north_star.sha256' "$record")" ] ||
  fail 'north star digest'
/usr/bin/grep -q 'status: \*\*unset\*\*' "$north_star" || fail 'north star is not marked unset'
! /usr/bin/grep -qE 'shipped-default|approved by|operator' "$north_star" ||
  fail 'north star placeholder carries a shipped-default marker or approval history'
ok 'the target gets an unset, target-owned north star with no marker and no approval history'

for installed in "$default_target" "$alt_target" "$repeat_target"; do
  ! /usr/bin/grep -raqE '/Users/|ghp_[A-Za-z0-9]{10}|github_pat_[A-Za-z0-9_]{10}|xox[abpr]-[A-Za-z0-9]{8}|sk-ant-|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]+PRIVATE KEY|ystack-shipped-default' \
    "$installed/.ystack" || fail "personal data or a credential pattern reached $installed"
  for absent in config manager .claude .github website templates routines reviewer work; do
    [ ! -e "$installed/.ystack/$absent" ] || fail "installed tree carries $absent"
  done
  # One packaged upstream source file cites its exception boundary by public PR URL.
  # That single provenance line is the only permitted operator-name hit; anything else fails.
  provenance=$(/usr/bin/grep -ral 'yihanzhu' "$installed/.ystack" || :)
  [ "$provenance" = "$installed/.ystack/adapters/local-git-materializer/v1/object-closure.c" ] ||
    fail "unexpected operator-name hit in $installed"
  [ "$(/usr/bin/grep -ac 'yihanzhu' "$provenance")" -eq 1 ] || fail 'provenance line count'
  /usr/bin/grep -aq 'Private exception boundary' "$provenance" || fail 'provenance line shape'
done
ok 'no personal configuration, credential pattern, or shipped-default marker reaches a target'

expect_refusal() {
  local want=$1 description=$2
  shift 2
  local output status=0
  output=$("$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$description was accepted"
  [ "$output" = "$want" ] || fail "$description returned '$output', wanted '$want'"
}
fresh_target() {
  local target="$tmp/fresh-$1"
  /bin/rm -rf -- "$target"
  /bin/mkdir -p "$target"
  /usr/bin/printf '%s\n' "$target"
}

occupied=$(fresh_target occupied); : >"$occupied/keep"
expect_refusal E_TARGET 'a non-empty target' "$installer" install "$manifest" profile.default.v1 "$occupied"
unreadable=$(fresh_target unreadable); : >"$unreadable/keep"; /bin/chmod 0300 "$unreadable"
expect_refusal E_TARGET 'a target whose emptiness cannot be read' "$installer" install "$manifest" profile.default.v1 "$unreadable"
/bin/chmod 0700 "$unreadable"
link_real=$(fresh_target link-real)
/bin/ln -s "$link_real" "$tmp/fresh-link"
expect_refusal E_TARGET 'a symlinked target' "$installer" install "$manifest" profile.default.v1 "$tmp/fresh-link"
inside="$root/packaging/v1/.packaging-test-target"
/bin/mkdir -p "$inside"
expect_refusal E_TARGET 'a target inside this repo' "$installer" install "$manifest" profile.default.v1 "$inside"
/bin/rmdir "$inside"
fake_home="$tmp/home"
/bin/mkdir -p "$fake_home/.config"
expect_refusal E_TARGET 'a target under home dotfiles' \
  /usr/bin/env HOME="$fake_home" "$installer" install "$manifest" profile.default.v1 "$fake_home/.config"
ok 'install refuses a non-empty, unreadable, symlinked, in-repo, or home-dotfile target'

target=$(fresh_target refusals)
# Every tampered fixture below is resealed: its release id is recomputed from its own
# edited body. Without that the id check alone would refuse them all and the checks
# each fixture is aimed at would never run.
reseal() {
  local file=$1 body_sha
  "$jq" -S -c '.body' "$file" >"$tmp/reseal-body.json"
  body_sha=$(sha_file "$tmp/reseal-body.json")
  "$jq" -S -c --arg id "release.$body_sha" '.id = $id' "$file" >"$tmp/reseal.json"
  /bin/mv "$tmp/reseal.json" "$file"
}
expect_refusal E_PROFILE 'an unknown profile id' "$installer" install "$manifest" profile.missing.v1 "$target"
"$jq" -S -c '.body.files[0].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$manifest" >"$tmp/tampered-digest.json"
reseal "$tmp/tampered-digest.json"
expect_refusal E_DIGEST 'a tampered file digest' "$installer" install "$tmp/tampered-digest.json" profile.default.v1 "$target"
"$jq" -S -c '.body.files[0].object_id = "0000000000000000000000000000000000000000"' \
  "$manifest" >"$tmp/tampered-object.json"
reseal "$tmp/tampered-object.json"
expect_refusal E_DIGEST 'a tampered Git object id' "$installer" install "$tmp/tampered-object.json" profile.default.v1 "$target"
"$jq" -S -c '(.body.files[] | select(.mode == "100644") | .mode) |= "100755"' \
  "$manifest" >"$tmp/tampered-mode.json"
reseal "$tmp/tampered-mode.json"
expect_refusal E_DIGEST 'a tampered file mode with the same blob' "$installer" install "$tmp/tampered-mode.json" profile.default.v1 "$target"
"$jq" -S -c '.body.activation = "live"' "$manifest" >"$tmp/active.json"
reseal "$tmp/active.json"
expect_refusal E_SHAPE 'a manifest claiming activation' "$installer" install "$tmp/active.json" profile.default.v1 "$target"
"$jq" -S -c '.body.source.commit_id = "0123456789012345678901234567890123456789"' \
  "$manifest" >"$tmp/stale.json"
reseal "$tmp/stale.json"
expect_refusal E_RELATION 'a manifest naming a commit this repo does not have' \
  "$installer" install "$tmp/stale.json" profile.default.v1 "$target"
# The generation is moved on every packaged core path too, so the manifest stays
# internally consistent and the repo-versus-manifest generation check is what refuses it.
"$jq" -S -c --arg generation "$generation" \
  --arg other 'g-0000000000000000000000000000000000000000000000000000000000000000' '
  def remap: if startswith("core/v2/generations/\($generation)/")
    then "core/v2/generations/\($other)/" + ltrimstr("core/v2/generations/\($generation)/")
    else . end;
  .body.core_contract.generation_id = $other |
  (.body.files[].path) |= remap | .body.files |= sort_by(.path) |
  (.body.profiles[].files) |= (map(remap) | sort)' "$manifest" >"$tmp/generation.json"
reseal "$tmp/generation.json"
expect_refusal E_RELATION 'a manifest naming another core generation' \
  "$installer" install "$tmp/generation.json" profile.default.v1 "$target"
[ -z "$(/bin/ls -A -- "$target")" ] || fail 'a refused install wrote into the target'
ok 'install refuses an unknown profile, a tampered digest, object, or mode, a claimed activation, and a stale release'

# The release id is the SHA-256 of the canonical body, and a profile's packaged set is
# derived from its own id and the manifest's generation. Neither is taken on trust.
"$jq" -S -c \
  '.id = "release.0000000000000000000000000000000000000000000000000000000000000000"' \
  "$manifest" >"$tmp/edited-id.json"
expect_refusal E_SHAPE 'a release id that is not the digest of its body' \
  "$installer" install "$tmp/edited-id.json" profile.default.v1 "$target"
"$jq" -S -c '[.body.profiles[] | select(.profile_id == "profile.default.v1").files][0] as $borrowed |
  (.body.profiles[] | select(.profile_id == "profile.alternative.v1").files) = $borrowed' \
  "$manifest" >"$tmp/swapped-profile.json"
reseal "$tmp/swapped-profile.json"
expect_refusal E_SHAPE "a profile carrying another profile's files" \
  "$installer" install "$tmp/swapped-profile.json" profile.default.v1 "$target"
"$jq" -S -c '(.body.profiles[] | select(.profile_id == "profile.default.v1").files) |=
  (. - ["adapters/claude-code-producer/v1/normalize.jq"])' "$manifest" >"$tmp/orphan-file.json"
reseal "$tmp/orphan-file.json"
expect_refusal E_SHAPE 'a packaged file no profile claims' \
  "$installer" install "$tmp/orphan-file.json" profile.default.v1 "$target"
[ -z "$(/bin/ls -A -- "$target")" ] || fail 'a refused install wrote into the target'
ok "install refuses a hand-edited release id, a borrowed profile file list, and an unclaimed packaged file"

# Whatever survives the derived checks still has to rebuild, byte for byte, from the
# commit the manifest names. These two edits are internally consistent and are refused
# only because the rebuilt release does not match them.
"$jq" -S -c '.body.files |=
    map(select(.path != "adapters/claude-code-producer/v1/normalize.jq")) |
  (.body.profiles[] | select(.profile_id == "profile.default.v1").files) |=
    (. - ["adapters/claude-code-producer/v1/normalize.jq"])' \
  "$manifest" >"$tmp/dropped-file.json"
reseal "$tmp/dropped-file.json"
expect_refusal E_DIGEST 'a manifest with one packaged file dropped' \
  "$installer" install "$tmp/dropped-file.json" profile.default.v1 "$target"
"$jq" -S -c '(.body.profiles[] | select(.profile_id == "profile.default.v1").files) |=
  ((. + ["adapters/codex-cli-producer/v1/normalize.jq"]) | sort)' \
  "$manifest" >"$tmp/extra-file.json"
reseal "$tmp/extra-file.json"
expect_refusal E_DIGEST "a profile handed an extra allowlisted file" \
  "$installer" install "$tmp/extra-file.json" profile.default.v1 "$target"
# The rebuild is a hard dependency: without the sibling builder nothing installs.
builderless="$tmp/builderless"
/bin/mkdir -p "$builderless/packaging"
/bin/cp -R "$root/packaging/v1" "$builderless/packaging/v1"
/bin/chmod -R u+w "$builderless"
/bin/rm -f "$builderless/packaging/v1/build-release.sh"
expect_refusal E_RUNTIME 'an installer with no sibling release builder' \
  "$builderless/packaging/v1/install.sh" install "$manifest" profile.default.v1 "$target"
[ -z "$(/bin/ls -A -- "$target")" ] || fail 'a refused install wrote into the target'
ok 'install reproduces the release from its own commit and refuses every manifest that differs'

/usr/bin/printf '{' >"$tmp/malformed.json"
expect_refusal E_PARSE 'a malformed manifest' "$installer" install "$tmp/malformed.json" profile.default.v1 "$target"
/bin/cat "$manifest" "$manifest" >"$tmp/multi-root.json"
expect_refusal E_PARSE 'a multi-root manifest' "$installer" install "$tmp/multi-root.json" profile.default.v1 "$target"
"$jq" . "$manifest" >"$tmp/pretty.json"
expect_refusal E_CANONICAL 'a non-canonical manifest' "$installer" install "$tmp/pretty.json" profile.default.v1 "$target"
/usr/bin/head -c 1200000 /dev/zero | /usr/bin/tr '\0' 'a' >"$tmp/oversized.json"
expect_refusal E_LIMIT 'an oversized manifest' "$installer" install "$tmp/oversized.json" profile.default.v1 "$target"
/bin/ln -s "$manifest" "$tmp/manifest-link.json"
expect_refusal E_RUNTIME 'a symlinked manifest' "$installer" install "$tmp/manifest-link.json" profile.default.v1 "$target"
expect_refusal E_RUNTIME 'a manifest that has moved away' \
  "$installer" install "$tmp/absent-release.json" profile.default.v1 "$target"
expect_refusal E_USAGE 'a missing target argument' "$installer" install "$manifest" profile.default.v1
[ -z "$(/bin/ls -A -- "$target")" ] || fail 'a refused install wrote into the target'
ok 'install refuses a malformed, multi-root, non-canonical, oversized, or symlink-reached manifest'

expect_refusal E_USAGE 'an unknown verb' "$builder" package "$commit" profile.default.v1
expect_refusal E_USAGE 'a short commit' "$builder" build-release "${commit:0:12}" profile.default.v1
expect_refusal E_USAGE 'a malformed profile id' "$builder" build-release "$commit" 'profile.Default.v1'
expect_refusal E_RELATION 'a commit this repo does not have' \
  "$builder" build-release 0123456789012345678901234567890123456789 profile.default.v1
# A commit where a bound adapter's bytes drifted from the object the profile
# pins is a stale profile: the builder must refuse rather than package the drift.
drift_index="$tmp/drift.index"
GIT_INDEX_FILE="$drift_index" /usr/bin/git -C "$root" read-tree "$commit" 2>/dev/null
drift_blob=$(printf '%s\n' '# drifted' | /usr/bin/git -C "$root" hash-object -w --stdin)
printf '100644 %s\t%s\n' "$drift_blob" adapters/codex-native-reviewer/v1/normalize.jq |
  GIT_INDEX_FILE="$drift_index" /usr/bin/git -C "$root" update-index --index-info
drift_tree=$(GIT_INDEX_FILE="$drift_index" /usr/bin/git -C "$root" write-tree)
drift_commit=$(GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.com GIT_AUTHOR_NAME=ci \
  GIT_AUTHOR_EMAIL=ci@example.com /usr/bin/git -C "$root" commit-tree "$drift_tree" -p "$commit" -m drift)
expect_refusal E_RELATION 'a commit whose bound adapter drifted from the pinned object' \
  "$builder" build-release "$drift_commit" profile.default.v1
expect_refusal E_PROFILE 'a profile that is not in the tree' \
  "$builder" build-release "$commit" profile.missing.v1
ok 'build-release refuses a bad verb, commit, or profile id'

fixture="$tmp/fixture"
/bin/mkdir -p "$fixture"
/usr/bin/git -C "$root" archive "$commit" profiles core scripts adapters | /usr/bin/tar -x -C "$fixture"
/bin/mkdir -p "$fixture/packaging"
/bin/cp -R "$root/packaging/v1" "$fixture/packaging/v1"
/bin/chmod -R u+w "$fixture"
"$jq" -S -c '.body.bindings |= map(if .role == "ci"
  then .package_ref.location.value = "config/models.conf" else . end)' \
  "$fixture/profiles/default/v1/profile.json" >"$fixture/profile.tmp"
/bin/mv "$fixture/profile.tmp" "$fixture/profiles/default/v1/profile.json"
/usr/bin/git -C "$fixture" init -q 2>/dev/null
/usr/bin/git -C "$fixture" -c user.email=test@example.invalid -c user.name=test add -A
/usr/bin/git -C "$fixture" -c user.email=test@example.invalid -c user.name=test \
  commit -q -m 'packaging path fixture'
expect_refusal E_PATH 'a profile binding personal configuration' \
  "$fixture/packaging/v1/build-release.sh" build-release \
  "$(/usr/bin/git -C "$fixture" rev-parse HEAD)" profile.default.v1
ok 'build-release refuses to package a path outside the shipped product shapes'

rebuilt="$tmp/rebuilt.json"
"$builder" build-release "$commit" profile.default.v1 profile.alternative.v1 >"$rebuilt"
/usr/bin/cmp -s "$manifest" "$rebuilt" || fail 'the unmodified manifest no longer reproduces'
final_target=$(fresh_target reproduce)
"$installer" install "$manifest" profile.alternative.v1 "$final_target" >/dev/null ||
  fail 'the unmodified manifest no longer installs'
tree_listing "$final_target" >"$tmp/listing-c"
tree_listing "$alt_target" >"$tmp/listing-d"
/usr/bin/cmp -s "$tmp/listing-c" "$tmp/listing-d" ||
  fail 'the reproduced install is not byte-identical to the first one'
ok 'the unmodified manifest reproduces and still installs byte-identically for both profiles'

printf 'target packaging: %s focused checks passed\n' "$pass"
