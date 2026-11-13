#!/usr/bin/env bash
# A failure report for the install's gate that failed (scripts/gates.sh): the
# evidence that explains it, in one place. Read-only; reads status fields only,
# never a Secret. It doesn't redact, though: Argo CD's sync messages can quote
# manifest fields, so read the report before sharing it. Always exits 0.
#
# Prints, in order:
#   - FAILED GATE: NAME
#   - scripts/status.sh's output (make status)
#   - for a site gate (site-SITE or site-SITE-STEP, such as site-site-b-import),
#     scripts/site-status.sh SITE's output (make site-status)
#   - for each hub Application that isn't Synced and Healthy, at most 20,
#     tagged "(waits for a site)" when it does (scripts/gates.sh app_rows):
#     its condition messages, its sync operation's message, and its first
#     five resources that aren't Healthy, with their health messages; each
#     message cut to 500 characters
#   - for a site's import gate (site-SITE-import), the conditions of
#     ManagedCluster SITE
# and writes the same text to .install/report.txt. When oc can't read the hub,
# says "could not read ...: REASON". With no failed gate recorded, says so and
# leaves .install/report.txt as it was.
#
# Runs against the hub in clusters.yaml, with its login (.config/NAME/kubeconfig).
#
# Usage: scripts/install-report.sh [GATE]
#   GATE defaults to the name in .install/failed-gate.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
. "$here/gates.sh"
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
  local json rc rows name sync health why n=0 more=0
  json=$(oc_read get applications.argoproj.io -n openshift-gitops -o json) && rc=0 || rc=$?
  if [ "$rc" = 2 ]; then
    echo "could not read Applications: $json"
  else
    rows=$(app_rows "$json" "$(unmatched_placements || true)" || true)
    while IFS=$'\t' read -r name sync health why; do
      [ -n "$name" ] && [ "$sync $health" != "Synced Healthy" ] || continue
      if [ "$n" -ge 20 ]; then more=$((more + 1)); continue; fi
      n=$((n + 1))
      echo "Application $name ($sync $health)$([ "$why" != site ] || echo " (waits for a site)")"
      jq -r --arg n "$name" 'def cut: if length > 500 then .[:500] + "…" else . end;
        .items[] | select(.metadata.name == $n)
        | (.status.conditions[]? | "  condition \(.type // "?"): \(.message // "" | cut)"),
          (.status.operationState // {} | select(.message) | "  operation \(.phase // "?"): \(.message | cut)"),
          ([.status.resources[]? | select(.health != null and .health.status != "Healthy")][:5][]
            | "  \(.kind) \(if .namespace then "\(.namespace)/" else "" end)\(.name): \(.health.status)\(if .health.message then ": \(.health.message | cut)" else "" end)")' \
        <<<"$json" 2>/dev/null
    done <<<"$rows"
    [ "$n" -gt 0 ] || echo none
    [ "$more" = 0 ] || echo "+$more more not Synced and Healthy"
  fi

  case "$gate_name" in
    site-*-import)
      [ -n "$site" ] || return 0
      echo
      echo "== ManagedCluster $site conditions"
      local out
      out=$(oc_read get managedclusters.cluster.open-cluster-management.io "$site" -o json) && rc=0 || rc=$?
      if [ "$rc" = 2 ]; then echo "could not read ManagedCluster $site: $out"; return 0; fi
      [ "$rc" != 0 ] || out=$(jq -r 'def cut: if length > 500 then .[:500] + "…" else . end;
        .status.conditions[]? | "  \(.type)=\(.status)\(if .reason then " (\(.reason))" else "" end)\(if .message then ": \(.message | cut)" else "" end)"' <<<"$out" 2>/dev/null)
      echo "${out:-  not created yet}" ;;
  esac
}

if [ -z "$gate_name" ]; then
  echo "no failed gate recorded ($dir/failed-gate doesn't exist): nothing to report"
  exit 0
fi
mkdir -p "$dir"
report | tee "$dir/report.txt"
exit 0
