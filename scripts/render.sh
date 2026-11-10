#!/usr/bin/env bash
# Render root/ and check it: kustomize builds, the library's "test" ops hold, and
# no input is left unset (no @name@ token outside the library's templatePatch).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
out="$(kustomize build root/)"
left="$(printf '%s\n' "$out" | grep -nE 'REQUIRED-[a-zA-Z]+' | grep -v 'regexFind "REQUIRED-' || true)"
[ -z "$left" ] || { echo "unset inputs:"; echo "$left"; exit 1; }
printf '%s\n' "$out" | grep -q 'name: deployment-root' || { echo "deployment-root missing"; exit 1; }
echo "root renders; every input is set."
