#!/usr/bin/env bash
# Render root/ and check it: kustomize builds, the library's "test" ops hold, no
# input is left unset (no REQUIRED-<name> outside the library's templatePatch),
# and every repository the root and apps/*.yaml read is one of the three set as
# inputs (libraryRepoURL, deploymentRepoURL, catalogRepoURL) or an @input@ token.
# The last check catches a URL left over from the repository you copied.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
out="$(kustomize build root/)"
left="$(printf '%s\n' "$out" | grep -nE 'REQUIRED-[a-zA-Z]+' | grep -v 'regexFind "REQUIRED-' || true)"
[ -z "$left" ] || { echo "unset inputs:"; echo "$left"; exit 1; }
printf '%s\n' "$out" | grep -q 'name: deployment-root' || { echo "deployment-root missing"; exit 1; }

value() { printf '%s\n' "$out" | sed -n "s/^ *$1: *//p" | head -1 | tr -d "'\""; }
norm() { sed -e 's#\.git$##' -e 's#/$##'; }
allowed="$(for n in libraryRepoURL deploymentRepoURL catalogRepoURL; do value "$n" | norm; done)"
stray="$( { printf '%s\n' "$out"; cat apps/*.yaml 2>/dev/null; } |
  sed -n "s/^ *repoURL: *//p" | tr -d "'\"" | grep -v '^@[a-zA-Z]*@$' | norm | sort -u |
  grep -vxF -f <(printf '%s\n' "$allowed") || true)"
[ -z "$stray" ] || { echo "repositories that aren't your library, deployment or catalog input:"; echo "$stray"; exit 1; }
echo "root renders; every input is set; every repository is an input."
