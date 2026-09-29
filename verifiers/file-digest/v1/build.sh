#!/usr/bin/env bash
# Builds the fixed file-digest verifier (ystack #437) with the host compiler
# and records its build identity. See work/fixed-file-digest-verifier/spec.md
# R1.2. Inactive: this script installs nothing, uses no network, and runs no
# program it builds.
set -euo pipefail
export LC_ALL=C
umask 077

usage() {
  /usr/bin/printf 'usage: build.sh build <out-dir>\n' >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
[ "$1" = build ] || usage
out=$2

case "$out" in
  /*) ;;
  *) out="$(/bin/pwd -P)/$out" ;;
esac

self_dir=$(CDPATH='' cd -P -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && /bin/pwd -P)
self_script="$self_dir/$(/usr/bin/basename -- "${BASH_SOURCE[0]}")"
source_name=verifier.c
source_path="$self_dir/$source_name"

/bin/mkdir -- "$out"

# The relative source name keeps the checkout path out of the object.
(CDPATH='' cd -- "$self_dir" && /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 "$source_name" -o "$out/verifier")
/bin/chmod 0555 "$out/verifier"

sha_file() { /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'; }

build_script_sha256=$(sha_file "$self_script")
source_sha256=$(sha_file "$source_path")
executable_sha256=$(sha_file "$out/verifier")
compiler_version_sha256=$(/usr/bin/cc --version | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
platform="$(/usr/bin/uname -s):$(/usr/bin/uname -m)"

/usr/bin/printf '{"build_script_sha256":"%s","compiler_path":"/usr/bin/cc","compiler_version_sha256":"%s","executable_sha256":"%s","flags":["-std=c11","-Wall","-Wextra","-Werror","-O2"],"kind":"file_digest_verifier_build","platform":"%s","sandbox_root":"/sandbox","schema_version":1,"source_sha256":"%s"}\n' \
  "$build_script_sha256" "$compiler_version_sha256" "$executable_sha256" "$platform" "$source_sha256" \
  > "$out/build-record.json"
