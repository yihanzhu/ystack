#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
builder="$root/packaging/v1/build-release.sh"

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

for shipped in "$builder" "$root/packaging/v1/packaging.jq"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing $shipped"
done
[ -x "$builder" ] || fail 'the builder must be executable'

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

expect_refusal() {
  local want=$1 description=$2
  shift 2
  local output status=0
  output=$("$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$description was accepted"
  [ "$output" = "$want" ] || fail "$description returned '$output', wanted '$want'"
}
expect_refusal E_USAGE 'an unknown verb' "$builder" package "$commit" profile.default.v1
expect_refusal E_USAGE 'a short commit' "$builder" build-release "${commit:0:12}" profile.default.v1
expect_refusal E_USAGE 'a malformed profile id' "$builder" build-release "$commit" 'profile.Default.v1'
expect_refusal E_RELATION 'a commit this repo does not have' \
  "$builder" build-release 0123456789012345678901234567890123456789 profile.default.v1
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

printf 'target packaging: %s focused checks passed\n' "$pass"
