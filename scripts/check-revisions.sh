#!/usr/bin/env bash
# Check that every Argo CD Application reading the library runs the pinned
# commit: the one revision parameter reaching every self-reference, including
# Applications that nested ApplicationSets generate.
# Usage: scripts/check-revisions.sh [--kubeconfig PATH]   (exit 1 on any offender)
set -Eeuo pipefail
args=(); [ "${1:-}" = --kubeconfig ] && args=(--kubeconfig "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")")
cd "$(dirname "$0")/.."
root="$(kustomize build root/)"
input() { printf '%s\n' "$root" | sed -n "s/^ *$1: *//p" | head -1 | tr -d "'\""; }
sha="$(input libraryRevision)"; repo="$(input libraryRepoURL)"
oc "${args[@]}" get applications.argoproj.io -n openshift-gitops -o json | python3 -c '
import json, sys
repo, sha = sys.argv[1].removesuffix(".git"), sys.argv[2]
apps = json.load(sys.stdin)["items"]
checked = bad = 0
for a in apps:
    spec, st = a["spec"], a.get("status", {}).get("sync", {})
    sources = spec.get("sources") or [spec.get("source", {})]
    revs = st.get("revisions") or [st.get("revision")]
    for i, s in enumerate(sources):
        if s.get("repoURL", "").removesuffix(".git") != repo:
            continue
        checked += 1
        want_ok = s.get("targetRevision") == sha
        got = revs[i] if i < len(revs) else None
        if not want_ok or got != sha:
            bad += 1
            print("OFF ", a["metadata"]["name"], "source", i, "targetRevision=%s synced=%s" % (s.get("targetRevision"), got))
print(f"{checked} library sources checked, {bad} not at {sha[:7]}")
sys.exit(1 if bad or not checked else 0)
' "$repo" "$sha"
