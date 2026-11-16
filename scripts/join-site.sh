#!/usr/bin/env bash
# Make a site part of the grid: label its ManagedCluster on the hub with the
# role and location from clusters.yaml. The hub then installs the site.
#
#   scripts/join-site.sh [NAME]     NAME defaults to the only site in clusters.yaml
#
# First it checks that your commits are pushed, and waits until the hub's
# deployment-root has synced origin/main's commit, so the site's files are on
# the hub before its labels: up to JOIN_WAIT_SECONDS (default 600), checking
# every JOIN_WAIT_INTERVAL seconds (default 15). JOIN_SITE_NO_WAIT=1 skips both.
# A site already labelled as clusters.yaml says is left alone, with no wait.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -le 1 ] || { echo "usage: join-site.sh [NAME]" >&2; exit 2; }
clusters_load "$here/.."
if [ "${1:-}" = hub ]; then name=hub; else name=$(site_name "${1:-}"); fi
role=$(cluster_field "$name" role)
[ "$role" != hub ] || { echo "error: $name is the hub; join-site.sh is for sites" >&2; exit 1; }
location=$(cluster_field "$name" location)
hub=$(hub_name)
cluster_login_ok "$hub"
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")

# Already labelled as clusters.yaml says: nothing to wait for or change.
current=$(oc get managedcluster "$name" -o json 2>/dev/null |
  jq -r '.metadata.labels // {} | [.["ai-grid/enabled"], .["ai-grid/role"], .location] | map(. // "") | join(" ")' 2>/dev/null || true)
if [ "$current" = "true $role $location" ]; then
  echo "$name: labels already set (ai-grid/enabled=true ai-grid/role=$role location=$location)."
  exit 0
fi

if [ "${JOIN_SITE_NO_WAIT:-}" != 1 ]; then
  repo="$here/.."
  git -C "$repo" fetch -q origin main || { echo "error: can't fetch origin main" >&2; exit 1; }
  unpushed=$(git -C "$repo" rev-list --count origin/main..HEAD)
  [ "$unpushed" = 0 ] || { echo "error: $unpushed commit(s) not pushed yet; push first: git push origin HEAD:main" >&2; exit 1; }
  want=$(git -C "$repo" rev-parse origin/main)
  timeout=${JOIN_WAIT_SECONDS:-600} interval=${JOIN_WAIT_INTERVAL:-15} waited=0 last=""
  while :; do
    got=$(oc get applications.argoproj.io deployment-root -n openshift-gitops \
      -o jsonpath='{.status.sync.status} {.status.sync.revision}' 2>/dev/null || true)
    [ "$got" = "Synced $want" ] && break
    if [ "$waited" -ge "$timeout" ]; then
      echo "error: the hub hasn't synced ${want:0:7} after $((timeout / 60)) minutes (deployment-root: ${got:-not found})." >&2
      echo "Run make status, or check deployment-root in Argo CD." >&2
      exit 1
    fi
    [ "$got" = "$last" ] || echo "Waiting for the hub to sync ${want:0:7} (deployment-root: ${got:-not found})."
    last=$got; sleep "$interval"; waited=$((waited + interval))
  done
  echo "The hub has synced ${want:0:7}."
fi
oc label managedcluster "$name" \
  ai-grid/enabled=true ai-grid/role="$role" location="$location" --overwrite
