#!/usr/bin/env bash
# Check which commit of the library each Argo CD Application on the hub reads.
# Read only; prints one line per Application that reads the library:
#   OK    NAME  every library source at your pin (libraryRevision in
#               root/applicationset.yaml)
#   HEAD  NAME  a library source at HEAD: an Application that one of the
#               library's own ApplicationSets generates (sites' rhoai-*,
#               maas-db-*, acm-submariner-*). The root can't pin those on the
#               library's main branch (docs/upstream-main-limits.md, L1), so
#               this is reported, not a failure.
#   OFF   NAME  a library source at any other revision
# Exits 1 if any Application is OFF.
#
#   scripts/check-revisions.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
pin=$(library_pin "$here/.." libraryRevision)
url=$(library_pin "$here/.." libraryRepoURL)
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] && [ -n "$url" ] || { echo "error: no libraryRevision or libraryRepoURL in root/applicationset.yaml" >&2; exit 1; }
json=$(KUBECONFIG=$(cluster_kubeconfig "$hub") oc get applications.argoproj.io -n openshift-gitops -o json)
rows=$(jq -r --arg u "${url%.git}" --arg p "$pin" '
  .items[] | .metadata.name as $n
  | [(.spec.sources // [.spec.source])[] | select(.repoURL != null and (.repoURL | rtrimstr(".git")) == $u) | .targetRevision // "HEAD"] as $revs
  | select($revs | length > 0)
  | if all($revs[]; . == $p) then "OK\t\($n)\t\($p)"
    elif all($revs[]; . == $p or . == "HEAD") then "HEAD\t\($n)\tHEAD"
    else "OFF\t\($n)\t\([$revs[] | select(. != $p)] | unique | join(","))" end' <<<"$json")
off=0 head=0
while IFS=$'\t' read -r state name rev; do
  [ -n "$state" ] || continue
  case "$state" in
    OK) printf '%-5s %-45s %s\n' OK "$name" "$rev" ;;
    HEAD) head=$((head + 1))
      printf '%-5s %-45s %s\n' HEAD "$name" "reads the library at HEAD; the root can't pin it (docs/upstream-main-limits.md, L1)" ;;
    OFF) off=$((off + 1)); printf '%-5s %-45s %s\n' OFF "$name" "at $rev, not your pin $pin" ;;
  esac
done <<<"$rows"
[ "$head" = 0 ] || echo "$head Application(s) read the library at HEAD: they follow upstream main, whatever you pin."
[ "$off" = 0 ] || { echo "$off Application(s) off your pin."; exit 1; }
