#!/usr/bin/env bash
# A failure report for the install's gate that failed (scripts/gates.sh): the
# evidence that explains it, in one place. Read-only; reads status fields only,
# never a Secret. Always exits 0.
#
# Prints, in order:
#   - FAILED GATE: NAME
#   - scripts/status.sh's output (make status)
#   - for a site gate (site-SITE or site-SITE-STEP, such as site-site-b-import),
#     scripts/site-status.sh SITE's output (make site-status)
#   - for each hub Application that isn't Synced and Healthy: its condition
#     messages, its sync operation's message, and its first five resources
#     that aren't Healthy, with their health messages
#   - for a site's import gate (site-SITE-import), the conditions of
#     ManagedCluster SITE
# and writes the same text to .install/report.txt.
#
# Runs against the hub in clusters.yaml, with its login (.config/NAME/kubeconfig).
#
# Usage: scripts/install-report.sh [GATE]
#   GATE defaults to the name in .install/failed-gate.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.." || exit 0
dir="$CLUSTERS_DIR/.install"

gate_name=${1:-}
[ -n "$gate_name" ] || gate_name=$(head -n 1 "$dir/failed-gate" 2>/dev/null || true)

# The site a site-* gate names: the longest site name that gate is
# site-NAME or starts with site-NAME-.
gate_site() {
  local s best=""
  for s in $(site_names); do
    case "$1" in "site-$s"|"site-$s-"*) [ ${#s} -le ${#best} ] || best=$s ;; esac
  done
  echo "$best"
}

report() {
  if [ -z "$gate_name" ]; then
    echo "no failed gate recorded ($dir/failed-gate doesn't exist): nothing to report"
    return 0
  fi
  echo "FAILED GATE: $gate_name"
  echo
  echo "== make status"
  "$here/status.sh" 2>&1 || true

  local site=""
  case "$gate_name" in site-*) site=$(gate_site "$gate_name") ;; esac
  if [ -n "$site" ]; then
    echo
    echo "== make site-status SITE=$site"
    "$here/site-status.sh" "$site" 2>&1 || true
  fi

  local hub; hub=$(hub_name)
  cluster_login_ok "$hub" 2>&1 || return 0
  KUBECONFIG=$(cluster_kubeconfig "$hub"); export KUBECONFIG

  echo
  echo "== Applications not Synced and Healthy"
  local out
  out=$(oc get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null |
    jq -r '.items[] | select(((.status.sync.status // "Unknown") + " " + (.status.health.status // "Unknown")) != "Synced Healthy")
      | "Application \(.metadata.name) (\(.status.sync.status // "Unknown") \(.status.health.status // "Unknown"))",
        (.status.conditions[]? | "  condition \(.type // "?"): \(.message // "")"),
        (.status.operationState // {} | select(.message) | "  operation \(.phase // "?"): \(.message)"),
        ([.status.resources[]? | select(.health != null and .health.status != "Healthy")][:5][]
          | "  \(.kind) \(if .namespace then "\(.namespace)/" else "" end)\(.name): \(.health.status)\(if .health.message then ": \(.health.message)" else "" end)")' 2>/dev/null)
  echo "${out:-none}"

  case "$gate_name" in
    site-*-import)
      [ -n "$site" ] || return 0
      echo
      echo "== ManagedCluster $site conditions"
      out=$(oc get managedclusters.cluster.open-cluster-management.io "$site" -o json 2>/dev/null |
        jq -r '.status.conditions[]? | "  \(.type)=\(.status)\(if .reason then " (\(.reason))" else "" end)\(if .message then ": \(.message)" else "" end)"' 2>/dev/null)
      echo "${out:-  not created yet}" ;;
  esac
}

mkdir -p "$dir"
report | tee "$dir/report.txt"
exit 0
