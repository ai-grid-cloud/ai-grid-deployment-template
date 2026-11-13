#!/usr/bin/env bash
# Check that an install reached its end state, and hand its endpoints to a test
# suite. Read-only: it changes nothing on any cluster.
#
#   scripts/ready-check.sh
#
# Inputs: clusters.yaml, each cluster's login (.config/NAME/kubeconfig, from make
# login), root/kustomization.yaml (the library pin), origin's main branch (read
# with git ls-remote and git fetch, with no prompt; when DEPLOYMENT_TOKEN_FILE
# names a readable file, git reads the token from it through a temporary
# GIT_ASKPASS helper), and .config/provider-admin-token (scripts/provider-admin.sh)
# when it exists.
#
# It prints one line per assertion, OK, FAIL or WARN, and exits 1 on any FAIL:
#   - every hub Application is Synced and Healthy, none excepted, not even those
#     that wait for a site;
#   - the MultiClusterHub is Running;
#   - the provider console, Keycloak and the Thanos query Routes answer, and the
#     Perses Service has a ready endpoint (it has no Route: the console reaches it
#     in-cluster);
#   - LokiStack redhat-ods-monitoring/usage-logs is Ready;
#   - each site is an available ManagedCluster with no ai-grid/ or location
#     label, and has no DataScienceCluster: imported, not added to the grid (a
#     missing resource type counts as none; any other API error is a FAIL);
#   - each ingress or combined site has its files here and on origin's main
#     (make site-add),
#     deployment-root is Synced at origin's main, and the certificate's issuer is
#     a DNS-01 ClusterIssuer on the site;
#   - the console lists no organizations, models or subscriptions (WARN, not
#     checked, without the provider-admin token).
# With no FAIL it writes .install/outputs.json (git-ignored): the hub's name, API
# and endpoint URLs, the token file's path (never the token), the library pin,
# and each site's role, location, API, apps domain and ACM name. persesURL is
# the Service's in-cluster URL, not reachable from outside the hub.
#
# Perses is the Cluster Observability Operator's Service and the Thanos Route
# ACM observability's; set PERSES_SERVICE or THANOS_ROUTE (NAMESPACE/NAME) to
# check others.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
. "$here/gates.sh"
clusters_load "$here/.."
dir=$CLUSTERS_DIR
: "${PERSES_SERVICE:=openshift-cluster-observability-operator/perses}"
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
if ! login=$(cluster_login_ok "$hub" 2>&1); then
  fail "hub $hub: ${login#error: }"; echo "Not ready: see FAIL above."; exit 1
fi
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
route_host() { oc get route "$2" -n "$1" -o json 2>/dev/null | jq -r '.spec.host // empty' 2>/dev/null || true; }
url() { [ -z "$1" ] || echo "https://$1"; }
ready_read() { # OC_ARG...: oc's output; empty when the resource or its type doesn't
  # exist. Any other error prints oc's last stderr line and returns 1.
  local out err rc=0
  err=$(mktemp); out=$(oc "$@" 2>"$err") || rc=$?
  if [ "$rc" != 0 ] && ! grep -qE "the server doesn't have a resource type|NotFound" "$err"; then
    grep . "$err" | tail -n 1 || echo "oc exited $rc"; rm -f "$err"; return 1
  fi
  rm -f "$err"; [ "$rc" != 0 ] || printf '%s\n' "$out"
}
service_ready() { # NAMESPACE NAME: the Service has at least one ready endpoint
  local out n
  out=$(ready_read get endpointslices.discovery.k8s.io -n "$1" -l "kubernetes.io/service-name=$2" -o json) ||
    { echo "Service $1/$2: $out"; return 1; }
  n=$(jq '[.items[]?.endpoints[]? | select(.conditions.ready != false)] | length' <<<"${out:-{\}}" 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] || { echo "Service $1/$2: no ready endpoint"; return 1; }
}

# origin's main, read from the remote, never from a local ref that may be old.
export GIT_TERMINAL_PROMPT=0
gitc() { git -C "$dir" -c credential.helper= "$@"; }
token_file=${DEPLOYMENT_TOKEN_FILE:-}
[ -z "$token_file" ] || case "$token_file" in /*) ;; *) token_file="$dir/$token_file" ;; esac
main_sha="" main_err="" main_read=""
read_main() { # sets main_sha, or main_err; reads origin once
  [ -z "$main_read" ] || return 0; main_read=1
  local out askpass=""
  if [ -n "$token_file" ] && [ -r "$token_file" ]; then
    askpass=$(mktemp "${TMPDIR:-/tmp}/git-askpass.XXXXXX"); chmod 700 "$askpass"
    # The helper holds the file's path, never its contents.
    printf '#!/bin/bash\ncase "$1" in Username*) echo x-access-token ;; *) head -n1 %q ;; esac\n' "$token_file" > "$askpass"
  fi
  if ! out=$(GIT_ASKPASS=${askpass:-${GIT_ASKPASS:-}} gitc ls-remote origin refs/heads/main 2>&1); then
    main_err="can't read origin: $(grep . <<<"$out" | tail -n 1)"
  elif [ -z "$out" ]; then main_err="origin has no main branch"
  else
    main_sha=${out%%[[:space:]]*}
    out=$(GIT_ASKPASS=${askpass:-${GIT_ASKPASS:-}} gitc fetch -q origin main 2>&1) ||
      main_err="can't fetch origin main: $(grep . <<<"$out" | tail -n 1)"
  fi
  [ -z "$askpass" ] || rm -f "$askpass"
}

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
check "Perses Service ${PERSES_SERVICE} has a ready endpoint (in-cluster)" service_ready "${PERSES_SERVICE%%/*}" "${PERSES_SERVICE#*/}"
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
  if ! mc=$(ready_read get managedclusters.cluster.open-cluster-management.io "$name" -o json); then
    fail "site $name: can't read its labels: $mc"
  else
    labels=$(jq -r '.metadata.labels // {} | keys[] | select(startswith("ai-grid/") or . == "location")' <<<"${mc:-{\}}" 2>/dev/null || true)
    if [ -z "$labels" ]; then ok "site $name: not added to the grid (no ai-grid/ or location label)"
    else fail "site $name: added to the grid by the install: labels $(echo $labels | sed 's/ /, /g')"; fi
  fi

  domain=""
  if login=$(cluster_login_ok "$name" 2>&1); then
    sk=$(cluster_kubeconfig "$name")
    if ! dsc=$(KUBECONFIG=$sk ready_read get datascienceclusters -A -o name); then
      fail "site $name: can't read its DataScienceClusters: $dsc"
    elif [ -z "$dsc" ]; then ok "site $name: no DataScienceCluster"
    else fail "site $name: has a DataScienceCluster ($(echo $dsc)): OpenShift AI comes with the Add, not the install"; fi
    domain=$(KUBECONFIG=$sk oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    [ -n "$domain" ] || fail "site $name: can't read its apps domain"
  else
    fail "site $name: ${login#error: }"; sk=""
  fi

  case "$role" in
    combined|ingress)
      read_main
      missing=""
      for f in "apps/$name-maas-tls.yaml" "sites/$name/maas-tls/certificate.yaml" "values/clusters/$name/rhoai.yaml"; do
        [ -e "$dir/$f" ] && [ -z "$main_err" ] && git -C "$dir" cat-file -e "$main_sha:$f" 2>/dev/null || missing+="${missing:+, }$f"
      done
      if [ -n "$main_err" ]; then fail "site $name ($role): its files on origin's main: $main_err"
      elif [ -z "$missing" ]; then ok "site $name ($role): its files are here and on origin's main"
      else fail "site $name ($role): missing here or on origin's main: $missing (make site-add SITE=$name, then commit and push)"; fi
      if [ -z "$root_checked" ]; then
        root_checked=1
        if [ -z "$main_err" ]; then check "deployment-root Synced at origin's main ($main_sha)" root_synced_to "$main_sha"
        else fail "deployment-root Synced at origin's main: $main_err"; fi
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

# No test content: the console lists no organizations, models or subscriptions.
none_listed() { # SERVICE NOUN: ai_grid.v1.SERVICE/List lists no NOUN
  local code n
  code=$(curl -sS -o "$tmp/body" -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' \
    -H 'Connect-Protocol-Version: 1' --data-binary '{}' -w '%{http_code}' \
    "https://$console_host/ai_grid.v1.$1/List" 2>/dev/null) || code=000
  n=$(jq -r '.total // (.items | length)' "$tmp/body" 2>/dev/null || true)
  if [ "$code" != 200 ] || [ -z "$n" ]; then fail "no ${2}s: ai_grid.v1.$1/List answered HTTP $code"
  elif [ "$n" = 0 ]; then ok "no ${2}s"
  else fail "no ${2}s: the console lists $n $2(s); the install creates none"; fi
}
if [ ! -f "$dir/$token_rel" ]; then
  warn "organizations, models and subscriptions not checked: no $token_rel (make provider-admin)"
elif [ -z "$console_host" ]; then
  fail "no organizations, models or subscriptions: no console Route to ask"
else
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  (umask 077; { printf 'Authorization: Bearer '; tr -d '\r\n' < "$dir/$token_rel"; printf '\n'; } > "$tmp/auth")
  none_listed Tenants organization
  none_listed Models model
  none_listed Subscriptions subscription
fi

[ "$failed" = 0 ] || { echo "Not ready: see FAIL above."; exit 1; }

rev=$(sed -n -E 's/^[[:space:]]*libraryRevision:[[:space:]]*([^[:space:]#]+).*/\1/p' "$dir/root/kustomization.yaml" | head -n1)
lib=$(sed -n -E 's/^[[:space:]]*libraryRepoURL:[[:space:]]*([^[:space:]#]+).*/\1/p' "$dir/root/kustomization.yaml" | head -n1)
mkdir -p "$dir/.install"
jq -n --arg hub "$hub" --arg api "$(cluster_field "$hub" api)" \
  --arg console "$(url "$console_host")" \
  --arg keycloak "$(url "$(route_host tenant-idp keycloak)")" \
  --arg perses "https://${PERSES_SERVICE#*/}.${PERSES_SERVICE%%/*}.svc:8080" \
  --arg thanos "$(url "$(route_host "${THANOS_ROUTE%%/*}" "${THANOS_ROUTE#*/}")")" \
  --arg token "$token_rel" --arg lib "$lib" --arg rev "$rev" --argjson sites "$sites_json" \
  '{hub: {name: $hub, api: $api, consoleURL: $console, keycloakURL: $keycloak, keycloakRealm: "tenants",
          persesURL: $perses, thanosURL: $thanos, lokiStack: "redhat-ods-monitoring/usage-logs"},
    providerAdminTokenFile: $token, library: {url: $lib, revision: $rev}, sites: $sites}' \
  > "$dir/.install/outputs.json.tmp"
mv "$dir/.install/outputs.json.tmp" "$dir/.install/outputs.json"
echo "Ready. Outputs: .install/outputs.json"
