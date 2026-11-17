#!/usr/bin/env bash
# Check a deployment repository before you push it: its root renders, no
# input is left unset (no REQUIRED-<name> outside the root's own check), no
# REQUIRED-<name> placeholder is left in the repository's other YAML or JSON
# files, and every repository the root and its apps/*.yaml read is one of the
# three set as inputs (libraryRepoURL, deploymentRepoURL, catalogRepoURL) or an
# @input@ token, and hub/catalog/ names the catalog repository and revision
# inputs.env does. The repository check catches a URL left over from a
# repository you copied.
#
# Usage: scripts/check-deployment.sh [DEPLOYMENT_DIR]   (default: this repository)
set -Eeuo pipefail
dir=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ $# -le 1 ] && [ -d "$dir/root" ] || { echo "Usage: check-deployment.sh [DEPLOYMENT_DIR] (a checkout with root/)" >&2; exit 2; }
. "$(dirname "$0")/deployment-inputs.sh"
deployment_render "$dir"
out=$DEPLOYMENT_ROOT
left="$(printf '%s\n' "$out" | grep -v 'regexFind "REQUIRED-' | grep -oE 'REQUIRED-[a-zA-Z]+' | sed 's/^REQUIRED-//' | sort -u | tr '\n' ' ' || true)"
# Placeholders in the repository's own files outside root/, such as your own
# app's hostnames: path:line:REQUIRED-<name>. The template's top-level tests/
# hold placeholders on purpose (fixtures), so they're skipped; a tests/
# directory anywhere else is still scanned.
placeholders="$(cd "$dir" && grep -rnoE --include='*.yaml' --include='*.yml' --include='*.json' --exclude=clusters-example.yaml \
  --exclude-dir=.git --exclude-dir=.library --exclude-dir=root 'REQUIRED-[a-zA-Z]+' . | sed 's#^\./##' | grep -v '^tests/' || true)"
[ -z "$left" ] || echo "unset inputs: ${left% }"
[ -z "$placeholders" ] || { echo "placeholders left in your files:"; echo "$placeholders"; }
[ -z "$left$placeholders" ] || exit 1
# clusters.yaml, when there is one: it loads (a hub, and each site's name and API).
if [ -f "$dir/.config/clusters.yaml" ] || [ -f "$dir/clusters.yaml" ]; then . "$(dirname "$0")/clusters.sh"; clusters_load "$dir" || exit 1; fi
# Every input the root declares must be set to a value.
unset_inputs=""
for n in deploymentRepoURL deploymentRevision catalogRepoURL catalogRevision keycloakOverlay hubCertManager libraryRepoURL libraryRevision; do
  v="$(deployment_input "$n")"
  [ -n "$v" ] && [ "$v" = "${v#REQUIRED-}" ] || unset_inputs="$unset_inputs $n"
done
# Per-site files the template's earlier versions wrote. The library's main
# branch doesn't read them: the sites they configure would lose those values.
left=$(cd "$dir" && { [ ! -d values/clusters ] || echo values/clusters/; ls -d apps/*-maas-tls.yaml sites/*/maas-tls 2>/dev/null || true; } | tr '\n' ' ')
[ -z "$left" ] || { echo "per-site files the library's main branch doesn't read: ${left% } (docs/install/README.md, \"Upgrade from an earlier template\")"; exit 1; }
# The two choices the root's templatePatch takes; another value fails the
# whole ApplicationSet on the hub, so it fails here first.
v="$(deployment_input keycloakOverlay)"; case "$v" in core|default|REQUIRED-*|"") ;; *) echo "keycloakOverlay is $v: core or default"; exit 1 ;; esac
v="$(deployment_input hubCertManager)"; case "$v" in library|platform|site|REQUIRED-*|"") ;; *) echo "hubCertManager is $v: library, platform or site"; exit 1 ;; esac
[ -z "$unset_inputs" ] || { echo "unset inputs:$unset_inputs"; exit 1; }
printf '%s\n' "$out" | grep -q 'name: deployment-root' || { echo "deployment-root missing from root/"; exit 1; }

norm() { sed -e 's#\.git$##' -e 's#/$##'; }
allowed="$(for n in libraryRepoURL deploymentRepoURL catalogRepoURL; do deployment_input "$n" | norm; done)"
stray="$( { printf '%s\n' "$out"; cat "$dir"/apps/*.yaml 2>/dev/null || true; } |
  sed -n "s/^ *repoURL: *//p" | tr -d "'\"" | grep -v '^@[a-zA-Z]*@$' | norm | sort -u |
  grep -vxF -f <(printf '%s\n' "$allowed") || true)"
[ -z "$stray" ] || { echo "repositories that aren't your library, deployment or catalog input:"; echo "$stray"; exit 1; }
# hub/catalog/ (scripts/set-inputs.sh writes it from inputs.env).
want="$(deployment_input catalogRepoURL) $(deployment_input catalogRevision)"
have="$(yq '.. | select(tag == "!!map") | (.repoURL, .revision, .targetRevision, .sourceRepos[]?) | select(. != null)' \
  "$dir"/hub/catalog/*.yaml 2>/dev/null | grep -vx -- --- | sort -u | tr '\n' ' ')"
for v in $have; do
  case " $want " in *" $v "*) ;; *) echo "hub/catalog names $have; your inputs are $want: run scripts/set-inputs.sh"; exit 1 ;; esac
done
echo "root renders; every input is set; every repository is an input."
