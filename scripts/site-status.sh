#!/usr/bin/env bash
# Show a site's state from the hub and the site (install guide, pages 5 to 7;
# make site-status). Read only:
#   - its ManagedCluster on the hub: JOINED and AVAILABLE, and its AI Grid role
#     (labels ai-grid/enabled=true and ai-grid/role, set by the provider
#     console's Add to AI Grid), or "not added to the grid yet"
#   - the hub's Applications for the site: sync and health
#   - !! for each of its add-ons on the hub whose ManifestApplied is False
#   - !! for each install namespace on the site stuck in Terminating
#   - for a site added as combined or ingress, the HTTP status of its MaaS hostname
#     (401 without a token), that it answers with the cluster's internal
#     certificate (not publicly trusted; curl never skips the check), or "not
#     installed yet" while it has no DataScienceCluster
#   - the models, subscriptions and auth policies on the site
#
#   scripts/site-status.sh [NAME]    NAME defaults to the only site in clusters.yaml
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
name=$(site_name "${1:-}")
hub=$(hub_name)
cluster_login_ok "$hub"
h() { KUBECONFIG=$(cluster_kubeconfig "$hub") oc "$@"; }

echo "== $name on the hub ($hub)"
mc=$(h get managedcluster "$name" -o json 2>/dev/null || true)
if [ -n "$mc" ]; then
  jq -r '"ManagedCluster: JOINED=" + ([.status.conditions[]? | select(.type == "ManagedClusterJoined") | .status][0] // "Unknown")
    + " AVAILABLE=" + ([.status.conditions[]? | select(.type == "ManagedClusterConditionAvailable") | .status][0] // "Unknown")' <<<"$mc"
else
  echo "ManagedCluster: not imported"
fi
# The role the provider console's Add to AI Grid gave the site; empty until then.
role=$(jq -r '.metadata.labels // {} | if .["ai-grid/enabled"] == "true" then .["ai-grid/role"] // "" else "" end' <<<"${mc:-{\}}" 2>/dev/null || true)
if [ -n "$role" ]; then echo "AI Grid: added as $role"; else echo "AI Grid: not added to the grid yet"; fi
apps=$(h get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null |
  jq -r --arg n "$name" '.items[] | select(.spec.destination.name == $n or (.metadata.name | test("(^|-)" + $n + "(-|$)")))
    | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")] | @tsv' || true)
if [ -n "$apps" ]; then echo "Applications:"; column -t <<<"$apps" | sed 's/^/  /'; else echo "Applications: none yet"; fi
# An add-on whose manifests the site refuses (such as Submariner's, into a
# namespace stuck in Terminating).
h get managedclusteraddons.addon.open-cluster-management.io -n "$name" -o json 2>/dev/null |
  jq -r '.items[] | . as $a | .status.conditions[]? | select(.type == "ManifestApplied" and .status == "False")
    | "  !! ManagedClusterAddOn \($a.metadata.name): ManifestApplied=False: \(.message // "")"' 2>/dev/null || true

echo "== $name"
if ! cluster_login_ok "$name"; then exit 0; fi
s() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }
{ s get ns -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true; } |
  { grep -E "$INSTALL_NS_RE" || true; } | while read -r ns; do echo "  !! Namespace $ns is Terminating"; done
case "$role" in
  combined|ingress)
    if [ -z "$(s get datasciencecluster -o name 2>/dev/null || true)" ]; then
      echo "MaaS: not installed yet (page 6)"
    else
      url="https://maas.$(s get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/v1/models"
      cf=$(mktemp); rc=0
      err=$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>&1 >"$cf") || rc=$?
      code=$(cat "$cf"); rm -f "$cf"
      # 60: the certificate isn't trusted. The gateway keeps the cluster's internal one
      # unless you add your own, so that answer means it's up.
      if [ "$rc" = 60 ] || [[ "$err" =~ "SSL certificate problem" ]]; then
        echo "MaaS $url: answers with the cluster's internal certificate, which isn't publicly trusted"
      else
        echo "MaaS $url: ${code:-000}${err:+ ($err)} (expect 401 with no token)"
      fi
    fi ;;
esac
out=$(s get llminferenceservices,maassubscriptions,maasauthpolicies -A 2>&1 || true)
if [ -n "$out" ]; then echo "Models, subscriptions and auth policies:"; sed 's/^/  /' <<<"$out"; fi
