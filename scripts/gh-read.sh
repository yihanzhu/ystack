#!/bin/bash
# The owner-only reader lives in the layer-pass skill, so it travels with the kit.
# This path stays for the hook message and AGENTS.md.
exec "$(dirname "$0")/../kit/skills/ystack-layer-pass/gh-read.sh" "$@"
