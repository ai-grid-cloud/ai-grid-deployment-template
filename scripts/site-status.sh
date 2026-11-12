#!/usr/bin/env bash
# Show a site's state from the hub and the site (install guide, pages 5 to 7;
# make site-status). Read only:
#   - its ManagedCluster on the hub: JOINED and AVAILABLE
#   - the hub's Applications for the site: sync and health
#   - for a combined or ingress site, the HTTP status of its MaaS hostname
#     (401 without a token, over trusted TLS)
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
apps=$(h get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null |
  jq -r --arg n "$name" '.items[] | select(.spec.destination.name == $n or (.metadata.name | test("(^|-)" + $n + "(-|$)")))
    | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")] | @tsv' || true)
if [ -n "$apps" ]; then echo "Applications:"; column -t <<<"$apps" | sed 's/^/  /'; else echo "Applications: none yet"; fi

echo "== $name"
if ! cluster_login_ok "$name"; then exit 0; fi
s() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }
case "$(cluster_field "$name" role)" in
  combined|ingress)
    url="https://maas.$(s get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/v1/models"
    code=$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>&1) || true
    echo "MaaS $url: $code (expect 401 with no token)" ;;
esac
out=$(s get llminferenceservices,maassubscriptions,maasauthpolicies -A 2>&1 || true)
if [ -n "$out" ]; then echo "Models, subscriptions and auth policies:"; sed 's/^/  /' <<<"$out"; fi
