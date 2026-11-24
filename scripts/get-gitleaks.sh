#!/bin/bash
# Prints the path of the pinned gitleaks binary. Downloads it first if it is
# missing, and checks the release digest before it unpacks anything.
#   get-gitleaks.sh             download if missing, then print the path
#   get-gitleaks.sh --no-fetch  print the path, or exit 2 if it is missing
set -euo pipefail

version=8.30.1
case "$(uname -s)_$(uname -m)" in
  Linux_x86_64) asset=linux_x64 digest=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  Linux_aarch64) asset=linux_arm64 digest=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
  Darwin_arm64) asset=darwin_arm64 digest=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
  Darwin_x86_64) asset=darwin_x64 digest=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
  *) echo "get-gitleaks: no pinned build for $(uname -s) $(uname -m)" >&2; exit 2 ;;
esac

bin=${XDG_CACHE_HOME:-$HOME/.cache}/ystack/gitleaks-$version/gitleaks
if [ ! -x "$bin" ]; then
  if [ "${1:-}" = --no-fetch ]; then
    echo "get-gitleaks: gitleaks $version is missing. Run scripts/get-gitleaks.sh once." >&2
    exit 2
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/gitleaks.tar.gz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_$asset.tar.gz"
  printf '%s  %s\n' "$digest" "$tmp/gitleaks.tar.gz" | shasum -a 256 -c - >/dev/null
  tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
  mkdir -p "$(dirname "$bin")"
  install -m 0755 "$tmp/gitleaks" "$bin"
fi
printf '%s\n' "$bin"
