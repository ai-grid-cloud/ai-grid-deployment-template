#!/usr/bin/env bash
# Check that an install reached its end state, and hand its endpoints to a test
# suite. Read-only: it changes nothing on any cluster.
#
#   scripts/ready-check.sh
#
# Inputs: clusters.yaml, each cluster's login (.config/NAME/kubeconfig, from make
# login), root/kustomization.yaml (the library pin), this repository's origin/main,
# and .config/provider-admin-token (scripts/provider-admin.sh) when it exists.
#
# It prints one line per assertion, OK, FAIL or WARN, and exits 1 on any FAIL:
#   - every hub Application is Synced and Healthy, none excepted, not even those
#     that wait for a site;
#   - the MultiClusterHub is Running;
#   - the provider console, Keycloak, Perses and the Thanos query Routes answer;
#   - LokiStack redhat-ods-monitoring/usage-logs is Ready;
#   - each site is an available ManagedCluster with no ai-grid/ or location
#     label, and has no DataScienceCluster: imported, not added to the grid;
#   - each ingress or combined site has its files here and on origin/main
#     (make site-add),
#     deployment-root is Synced at origin/main, and the certificate's issuer is a
#     DNS-01 ClusterIssuer on the site;
#   - the console lists no organizations (WARN, not checked, without the
#     provider-admin token).
# With no FAIL it writes .install/outputs.json (git-ignored): the hub's name, API
# and endpoint URLs, the token file's path (never the token), the library pin,
# and each site's role, location, API, apps domain and ACM name.
#
# The Perses and Thanos Routes default to the Cluster Observability Operator's
# and ACM observability's; set PERSES_ROUTE (NAMESPACE/NAME) or THANOS_ROUTE to
# check others.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
. "$here/gates.sh"
clusters_load "$here/.."
dir=$CLUSTERS_DIR
: "${PERSES_ROUTE:=openshift-cluster-observability-operator/perses}"
: "${THANOS_ROUTE:=open-cluster-management-observability/rbac-query-proxy}"
token_rel=.config/provider-admin-token

failed=0
ok() { echo "OK   $*"; }
fail() { echo "FAIL $*"; failed=1; }
warn() { echo "WARN $*"; }
check() { # DESCRIPTION CHECK [ARG...]: OK, or FAIL with the check's reason
  local what=$1 out; shift
  if out=$("$@" 2>&1); then ok "$what"; else fail "$what: $(grep . <<<"$out" | tail -n 1)"; fi
}

hub=$(hub_name)
cluster_login_ok "$hub"
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
route_host() { oc get route "$2" -n "$1" -o json 2>/dev/null | jq -r '.spec.host // empty' 2>/dev/null || true; }
url() { [ -z "$1" ] || echo "https://$1"; }

# The hub.
check "hub Applications Synced and Healthy" apps_healthy --strict
check "MultiClusterHub Running" mch_running
console_route=$(oc get route -n ai-grid-provider-console -o json 2>/dev/null | jq -r '.items[0].metadata.name // empty' 2>/dev/null || true)
if [ -n "$console_route" ]; then
  check "provider console answers" route_answers ai-grid-provider-console "$console_route"
  console_host=$(route_host ai-grid-provider-console "$console_route")
else
  fail "provider console answers: no Route in ai-grid-provider-console"; console_host=""
fi
check "Keycloak answers" route_answers tenant-idp keycloak
check "Perses answers" route_answers "${PERSES_ROUTE%%/*}" "${PERSES_ROUTE#*/}"
check "Thanos query answers" route_answers "${THANOS_ROUTE%%/*}" "${THANOS_ROUTE#*/}"
loki=$(oc get lokistack usage-logs -n redhat-ods-monitoring -o json 2>/dev/null |
  jq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown"' 2>/dev/null || true)
if [ "$loki" = True ]; then ok "LokiStack redhat-ods-monitoring/usage-logs Ready"
else fail "LokiStack redhat-ods-monitoring/usage-logs Ready: ${loki:-not created yet}"; fi

# The sites: imported and waiting, with what a later Add needs.
sites_json='[]' root_checked=""
for name in $(site_names); do
  role=$(cluster_field "$name" role)
  check "site $name: ManagedCluster available" managedcluster_available "$name"
  labels=$(oc get managedclusters.cluster.open-cluster-management.io "$name" -o json 2>/dev/null |
    jq -r '.metadata.labels // {} | keys[] | select(startswith("ai-grid/") or . == "location")' 2>/dev/null || true)
  if [ -z "$labels" ]; then ok "site $name: not added to the grid (no ai-grid/ or location label)"
  else fail "site $name: added to the grid by the install: labels $(echo $labels | sed 's/ /, /g')"; fi

  domain=""
  if login=$(cluster_login_ok "$name" 2>&1); then
    sk=$(cluster_kubeconfig "$name")
    dsc=$(KUBECONFIG=$sk oc get datascienceclusters -A -o name 2>/dev/null || true)
    if [ -z "$dsc" ]; then ok "site $name: no DataScienceCluster"
    else fail "site $name: has a DataScienceCluster ($(echo $dsc)): OpenShift AI comes with the Add, not the install"; fi
    domain=$(KUBECONFIG=$sk oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    [ -n "$domain" ] || fail "site $name: can't read its apps domain"
  else
    fail "site $name: ${login#error: }"; sk=""
  fi

  case "$role" in
    combined|ingress)
      missing=""
      for f in "apps/$name-maas-tls.yaml" "sites/$name/maas-tls/certificate.yaml" "values/clusters/$name/rhoai.yaml"; do
        [ -e "$dir/$f" ] && git -C "$dir" cat-file -e "origin/main:$f" 2>/dev/null || missing+="${missing:+, }$f"
      done
      if [ -z "$missing" ]; then ok "site $name ($role): its files are here and on origin/main"
      else fail "site $name ($role): missing here or on origin/main: $missing (make site-add SITE=$name, then commit and push)"; fi
      if [ -z "$root_checked" ]; then
        root_checked=1
        if sha=$(git -C "$dir" rev-parse --verify -q origin/main); then
          check "deployment-root Synced at origin/main" root_synced_to "$sha"
        else fail "deployment-root Synced at origin/main: this repository has no origin/main (git fetch origin)"; fi
      fi
      issuer=$(sed -n -E '/issuerRef:/,$ s/^[[:space:]]+name:[[:space:]]*([^[:space:]#]+).*/\1/p' \
        "$dir/sites/$name/maas-tls/certificate.yaml" 2>/dev/null | head -n1)
      if [ -z "$issuer" ]; then fail "site $name: no issuer in sites/$name/maas-tls/certificate.yaml"
      elif [ -n "$sk" ]; then
        issuers=$(KUBECONFIG=$sk oc get clusterissuers.cert-manager.io -o json 2>/dev/null |
          jq -r '.items[] | select(any(.spec.acme.solvers[]?; .dns01 != null)) | .metadata.name' 2>/dev/null || true)
        if grep -qx -- "$issuer" <<<"$issuers"; then ok "site $name: ClusterIssuer $issuer is DNS-01"
        else fail "site $name: ClusterIssuer $issuer isn't a DNS-01 ClusterIssuer on it; those are: $(echo ${issuers:-none})"; fi
      fi ;;
  esac
  sites_json=$(jq -c --arg n "$name" --arg r "$role" --arg l "$(cluster_field "$name" location)" \
    --arg a "$(cluster_field "$name" api)" --arg d "$domain" \
    '. + [{name: $n, role: $r, location: $l, api: $a, appsDomain: $d, acmName: $n}]' <<<"$sites_json")
done

# No test content: the console lists no organizations.
if [ ! -f "$dir/$token_rel" ]; then
  warn "organizations not checked: no $token_rel (make provider-admin)"
elif [ -z "$console_host" ]; then
  fail "no organizations: no console Route to ask"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  (umask 077; { printf 'Authorization: Bearer '; tr -d '\r\n' < "$dir/$token_rel"; printf '\n'; } > "$tmp/auth")
  code=$(curl -sS -o "$tmp/body" -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' \
    -H 'Connect-Protocol-Version: 1' --data-binary '{}' -w '%{http_code}' \
    "https://$console_host/ai_grid.v1.Tenants/List" 2>/dev/null) || code=000
  n=$(jq -r '(.items // []) | length' "$tmp/body" 2>/dev/null || true)
  if [ "$code" != 200 ] || [ -z "$n" ]; then fail "no organizations: ai_grid.v1.Tenants/List answered HTTP $code"
  elif [ "$n" = 0 ]; then ok "no organizations"
  else fail "no organizations: the console lists $n organization(s); the install creates none"; fi
fi

[ "$failed" = 0 ] || { echo "Not ready: see FAIL above."; exit 1; }

rev=$(sed -n -E 's/^[[:space:]]*libraryRevision:[[:space:]]*([^[:space:]#]+).*/\1/p' "$dir/root/kustomization.yaml" | head -n1)
lib=$(sed -n -E 's/^[[:space:]]*libraryRepoURL:[[:space:]]*([^[:space:]#]+).*/\1/p' "$dir/root/kustomization.yaml" | head -n1)
mkdir -p "$dir/.install"
jq -n --arg hub "$hub" --arg api "$(cluster_field "$hub" api)" \
  --arg console "$(url "$console_host")" \
  --arg keycloak "$(url "$(route_host tenant-idp keycloak)")" \
  --arg perses "$(url "$(route_host "${PERSES_ROUTE%%/*}" "${PERSES_ROUTE#*/}")")" \
  --arg thanos "$(url "$(route_host "${THANOS_ROUTE%%/*}" "${THANOS_ROUTE#*/}")")" \
  --arg token "$token_rel" --arg lib "$lib" --arg rev "$rev" --argjson sites "$sites_json" \
  '{hub: {name: $hub, api: $api, consoleURL: $console, keycloakURL: $keycloak, keycloakRealm: "tenants",
          persesURL: $perses, thanosURL: $thanos, lokiStack: "redhat-ods-monitoring/usage-logs"},
    providerAdminTokenFile: $token, library: {url: $lib, revision: $rev}, sites: $sites}' \
  > "$dir/.install/outputs.json.tmp"
mv "$dir/.install/outputs.json.tmp" "$dir/.install/outputs.json"
echo "Ready. Outputs: .install/outputs.json"
