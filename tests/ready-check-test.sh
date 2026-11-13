#!/usr/bin/env bash
# Tests for scripts/ready-check.sh with a stub oc and a stub curl (no cluster,
# no console). The stub oc logs its arguments to $STUB_DIR/argv.log and answers
# from $STUB_DIR/CLUSTER/, CLUSTER being the directory of the KUBECONFIG it's
# given (.config/CLUSTER/kubeconfig); a missing file is an error, as for a
# resource that doesn't exist, and FILE.err next to it is the error oc prints
# instead. The stub curl logs its arguments to $STUB_DIR/curl.log, copies the
# header files it's given to $STUB_DIR/headers, answers a Connect call to
# ai_grid.v1.SERVICE/List with $STUB_DIR/SERVICE.json ({} when there's none),
# and answers every call with HTTP 200. Each deployment repository has a local
# bare repository as its origin.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SECRET=SENTINEL-provider-admin-token

run() { # runs ready-check.sh in $D with the stubs reading $W; sets rc and out
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/ready-check.sh" 2>&1) && rc=0 || rc=$?
}
t() { # name want_rc expect_grep [check...]: each check is a command that must succeed
  local name=$1 want=$2 expect=$3; shift 3; local check ok=1
  total=$((total+1))
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && ! grep -q "$SECRET" <<<"$out"; then
    for check in "$@"; do eval "$check" || { ok=0; echo "      check failed: $check"; }; done
  else ok=0; fi
  if [ "$ok" = 1 ]; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; a=" $* "
c=$(basename "$(dirname "${KUBECONFIG:-/none/x}")")
ans() { [ -f "$d/$c/$1.err" ] && { cat "$d/$c/$1.err" >&2; exit 1; }; [ -f "$d/$c/$1" ] || { echo "NotFound" >&2; exit 1; }; cat "$d/$c/$1"; }
case "$a" in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io deployment-root "*) ans deployment-root.json ;;
  *" get applications.argoproj.io -n openshift-gitops "*) ans apps.json ;;
  *" get placements."*) ans placements.json ;;
  *" get multiclusterhub "*) ans mch.json ;;
  *" get route -n "*) ans "route-$4.json" ;;
  *" get route "*) ans "route-$5-$3.json" ;;
  *" get endpointslices.discovery.k8s.io -n openshift-cluster-observability-operator -l kubernetes.io/service-name=perses "*) ans perses-endpointslices.json ;;
  *" get lokistack usage-logs "*) ans lokistack.json ;;
  *" get managedclusters.cluster.open-cluster-management.io "*) ans "mc-$3.json" ;;
  *" get datascienceclusters "*) ans dsc ;;
  *" get ingresses.config.openshift.io cluster "*) ans domain ;;
  *" get clusterissuers.cert-manager.io "*) ans issuers.json ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.log"
out="" prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  [ "$prev" = -H ] && case "$a" in @*) cat "${a#@}" >> "$STUB_DIR/headers" ;; esac
  prev=$a
done
case " $* " in *"/ai_grid.v1."*)
  svc=$(sed -E 's#.*/ai_grid\.v1\.([A-Za-z]+)/List.*#\1#' <<<"$*")
  [ -n "$out" ] && { cat "$STUB_DIR/$svc.json" 2>/dev/null || echo '{}'; } > "$out" ;; esac
printf 200
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

# A deployment repository: the template's scripts and root, two sites (combined
# site-b with its files committed, inference site-c), every login, and the
# provider-admin token. origin, a local bare repository, has its one commit as main.
newrepo() { # DIR [SITES_YAML]
  local d=$1 sites=${2:-$'  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n  - {name: site-c, role: inference, location: us-west, api: "https://api.site-c.example.com:6443"}'}
  mkdir -p "$d/.config/hub" "$d/.config/site-b" "$d/.config/site-c"
  cp -R "$SRC/scripts" "$SRC/root" "$d/"
  : > "$d/.config/hub/kubeconfig"; : > "$d/.config/site-b/kubeconfig"; : > "$d/.config/site-c/kubeconfig"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n%s\n' "$sites" > "$d/clusters.yaml"
  mkdir -p "$d/apps" "$d/sites/site-b/maas-tls" "$d/values/clusters/site-b"
  echo "kind: Application" > "$d/apps/site-b-maas-tls.yaml"
  sed -e 's/APPS_DOMAIN/apps.site-b.example.com/' -e 's/DNS01_ISSUER/letsencrypt-dns/' \
    "$SRC/site-template/sites/SITE/maas-tls/certificate.yaml" > "$d/sites/site-b/maas-tls/certificate.yaml"
  echo "maas: {}" > "$d/values/clusters/site-b/rhoai.yaml"
  (umask 077; printf '%s\n' "$SECRET" > "$d/.config/provider-admin-token")
  git -C "$d" init -q && git -C "$d" add -A . ':!.config' &&
    git -C "$d" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm init &&
    git init -q --bare "$d.origin.git" && git -C "$d" remote add origin "$d.origin.git" &&
    git -C "$d" push -q origin HEAD:refs/heads/main && git -C "$d" fetch -q origin
}
app() { printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s"},"health":{"status":"%s"}}}' "$@"; }
route() { printf '{"metadata":{"name":"%s"},"spec":{"host":"%s"}}' "$1" "$2"; }
mc() { # NAME [LABELS_JSON]
  local labels=${2:-}; [ -n "$labels" ] || labels='{"name":"x","vendor":"OpenShift"}'
  printf '{"metadata":{"name":"%s","labels":%s},"status":{"conditions":[{"type":"ManagedClusterJoined","status":"True"},{"type":"ManagedClusterConditionAvailable","status":"True"}]}}' "$1" "$labels"
}
# Every answer of a ready install, for repository $D.
ready() { # W
  local w=$1 h=$1/hub sha
  sha=$(git -C "$D" rev-parse origin/main)
  mkdir -p "$h" "$w/site-b" "$w/site-c"
  echo "{\"items\":[$(app acm Synced Healthy),$(app tenant-idp Synced Healthy),$(app limitador-redis Synced Healthy)]}" > "$h/apps.json"
  echo '{"items":[{"status":{"phase":"Running"}}]}' > "$h/mch.json"
  echo "{\"items\":[$(route console console.apps.hub.example.com)]}" > "$h/route-ai-grid-provider-console.json"
  route console console.apps.hub.example.com > "$h/route-ai-grid-provider-console-console.json"
  route keycloak keycloak.apps.hub.example.com > "$h/route-tenant-idp-keycloak.json"
  echo '{"items":[{"endpoints":[{"addresses":["10.0.0.9"],"conditions":{"ready":true}}]}]}' > "$h/perses-endpointslices.json"
  route rbac-query-proxy thanos.apps.hub.example.com > "$h/route-open-cluster-management-observability-rbac-query-proxy.json"
  echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}' > "$h/lokistack.json"
  mc site-b > "$h/mc-site-b.json"; mc site-c > "$h/mc-site-c.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"%s"},"health":{"status":"Healthy"}}}' "$sha" > "$h/deployment-root.json"
  for s in site-b site-c; do : > "$w/$s/dsc"; printf 'apps.%s.example.com' "$s" > "$w/$s/domain"; done
  echo '{"items":[{"metadata":{"name":"letsencrypt-dns"},"spec":{"acme":{"solvers":[{"dns01":{"route53":{}}}]}}},{"metadata":{"name":"letsencrypt-http"},"spec":{"acme":{"solvers":[{"http01":{}}]}}}]}' > "$w/site-b/issuers.json"
}
OUT() { echo "$D/.install/outputs.json"; }
jqt() { jq -e "$1" "$(OUT)" >/dev/null; }

D="$T/repo"; newrepo "$D"
W="$T/ready"; ready "$W"; run
t "all ready: OK and outputs.json" 0 "^OK " \
  '! grep -q "^FAIL" <<<"$out"' 'grep -q "^OK .*no organizations" <<<"$out"' \
  'jqt ".hub.name == \"hub\" and .hub.api == \"https://api.hub.example.com:6443\""' \
  'jqt ".hub.consoleURL == \"https://console.apps.hub.example.com\""' \
  'jqt ".hub.keycloakURL == \"https://keycloak.apps.hub.example.com\" and .hub.keycloakRealm == \"tenants\""' \
  'jqt ".hub.persesURL == \"https://perses.openshift-cluster-observability-operator.svc:8080\" and .hub.thanosURL == \"https://thanos.apps.hub.example.com\""' \
  'jqt ".hub.lokiStack == \"redhat-ods-monitoring/usage-logs\""' \
  'jqt ".providerAdminTokenFile == \".config/provider-admin-token\""' \
  'jqt ".library.url == \"https://github.com/ai-grid-cloud/ai-grid-cluster-gitops.git\" and (.library.revision | test(\"^[0-9a-f]{40}$\"))"' \
  'jqt "(.sites | length) == 2"' \
  'jqt ".sites[0] == {name: \"site-b\", role: \"combined\", location: \"us-east\", api: \"https://api.site-b.example.com:6443\", appsDomain: \"apps.site-b.example.com\", acmName: \"site-b\"}"' \
  'jqt ".sites[1].name == \"site-c\" and .sites[1].role == \"inference\" and .sites[1].appsDomain == \"apps.site-c.example.com\""' \
  'jqt "(.hub | keys) == ([\"api\",\"consoleURL\",\"keycloakRealm\",\"keycloakURL\",\"lokiStack\",\"name\",\"persesURL\",\"thanosURL\"])"' \
  'jqt "(keys) == ([\"hub\",\"library\",\"providerAdminTokenFile\",\"sites\"])"' \
  'grep -q "Authorization: Bearer $SECRET" "$W/headers"' '! grep -q "$SECRET" "$W/curl.log"' \
  'grep -q "https://console.apps.hub.example.com/ai_grid.v1.Tenants/List" "$W/curl.log"' \
  'grep -q "^OK .*no models" <<<"$out"' 'grep -q "^OK .*no subscriptions" <<<"$out"' \
  'grep -q "https://console.apps.hub.example.com/ai_grid.v1.Models/List" "$W/curl.log"' \
  'grep -q "https://console.apps.hub.example.com/ai_grid.v1.Subscriptions/List" "$W/curl.log"' \
  'grep -q "^OK .*Perses" <<<"$out"' \
  '! grep -qwE "apply|create|delete|patch|edit|label|annotate|replace|scale|rollout" "$W/argv.log"'

W="$T/labelled"; ready "$W"; mc site-b '{"ai-grid/enabled":"true","ai-grid/role":"combined"}' > "$W/hub/mc-site-b.json"
rm -f "$(OUT)"; run
t "a site labelled ai-grid/enabled: FAIL" 1 "^FAIL .*site-b.*ai-grid/enabled" '[ ! -f "$(OUT)" ]'

W="$T/dsc"; ready "$W"; echo "datasciencecluster.datasciencecluster.opendatahub.io/default-dsc" > "$W/site-c/dsc"; run
t "a DataScienceCluster on a site: FAIL" 1 "^FAIL .*site-c.*DataScienceCluster" '[ ! -f "$(OUT)" ]'

W="$T/nofiles"; ready "$W"; git -C "$D" rm -q values/clusters/site-b/rhoai.yaml; run
git -C "$D" checkout -q HEAD -- values/clusters/site-b/rhoai.yaml
t "missing site files for an ingress site: FAIL" 1 "^FAIL .*site-b.*values/clusters/site-b/rhoai.yaml" '[ ! -f "$(OUT)" ]'

D="$T/inference"; newrepo "$D" '  - {name: site-c, role: inference, location: us-west, api: "https://api.site-c.example.com:6443"}'
rm -rf "$D/apps" "$D/sites" "$D/values"
W="$T/inference-w"; ready "$W"; rm -f "$W/hub/deployment-root.json"; run
t "an inference site needs no files" 0 "^OK .*site-c" '! grep -q "^FAIL" <<<"$out"' \
  '! grep -q clusterissuers "$W/argv.log"' 'jqt ".sites == [{name: \"site-c\", role: \"inference\", location: \"us-west\", api: \"https://api.site-c.example.com:6443\", appsDomain: \"apps.site-c.example.com\", acmName: \"site-c\"}]"'
D="$T/repo"

W="$T/org"; ready "$W"; echo '{"items":[{"id":"7c0e","name":"org1"}],"size":1}' > "$W/Tenants.json"; rm -f "$(OUT)"; run
t "an organization exists: FAIL" 1 "^FAIL .*1 organization" '[ ! -f "$(OUT)" ]'

W="$T/model"; ready "$W"; echo '{"size":1,"total":1,"items":[{"id":"m1"}]}' > "$W/Models.json"; rm -f "$(OUT)"; run
t "a model exists: FAIL" 1 "^FAIL .*1 model" '[ ! -f "$(OUT)" ]'

W="$T/sub"; ready "$W"; echo '{"items":[{"id":"s1"},{"id":"s2"}]}' > "$W/Subscriptions.json"; rm -f "$(OUT)"; run
t "a subscription exists: FAIL (no total: counts items)" 1 "^FAIL .*2 subscription" '[ ! -f "$(OUT)" ]'

W="$T/forbidden"; ready "$W"
echo 'Error from server (Forbidden): datascienceclusters.datasciencecluster.opendatahub.io is forbidden: User "x" cannot list resource "datascienceclusters"' > "$W/site-c/dsc.err"
rm -f "$(OUT)"; run
t "an API error reading a site's DataScienceClusters: FAIL, not none" 1 "^FAIL .*site-c.*Forbidden" \
  '! grep -q "^OK .*site-c: no DataScienceCluster" <<<"$out"' '[ ! -f "$(OUT)" ]'

W="$T/notype"; ready "$W"
echo 'error: the server doesn'"'"'t have a resource type "datascienceclusters"' > "$W/site-c/dsc.err"; run
t "no DataScienceCluster type on a site: none" 0 "^OK .*site-c: no DataScienceCluster"

W="$T/mcforbidden"; ready "$W"
echo 'Error from server (Forbidden): managedclusters.cluster.open-cluster-management.io "site-b" is forbidden' > "$W/hub/mc-site-b.json.err"
rm -f "$(OUT)"; run
t "an API error reading a ManagedCluster's labels: FAIL" 1 "^FAIL .*site-b.*labels.*Forbidden" \
  '! grep -q "^OK .*site-b: not added" <<<"$out"'

W="$T/noperses"; ready "$W"; echo '{"items":[{"endpoints":[{"addresses":["10.0.0.9"],"conditions":{"ready":false}}]}]}' > "$W/hub/perses-endpointslices.json"
rm -f "$(OUT)"; run
t "Perses Service with no ready endpoint: FAIL" 1 "^FAIL .*Perses.*no ready endpoint" '[ ! -f "$(OUT)" ]'

W="$T/nohublogin"; ready "$W"; mv "$D/.config/hub/kubeconfig" "$T/hub-kubeconfig.bak"; run
mv "$T/hub-kubeconfig.bak" "$D/.config/hub/kubeconfig"
t "no hub login: FAIL, Not ready" 1 "^FAIL .*hub.*make login" 'grep -q "^Not ready" <<<"$out"'

# origin's main is ahead of this repository's origin/main ref: the check reads the remote.
D="$T/ahead"; newrepo "$D"
old=$(git -C "$D" rev-parse origin/main)
git -C "$D" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m ahead
git -C "$D" push -q origin HEAD:refs/heads/main; new=$(git -C "$D" rev-parse HEAD)
git -C "$D" reset -q --hard "$old"; git -C "$D" update-ref refs/remotes/origin/main "$old"
W="$T/ahead-w"; ready "$W"
printf '{"status":{"sync":{"status":"Synced","revision":"%s"},"health":{"status":"Healthy"}}}' "$new" > "$W/hub/deployment-root.json"
printf 'SENTINEL-deploy-token\n' > "$D/.config/deployment-token"
out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" DEPLOYMENT_TOKEN_FILE=.config/deployment-token "$D/scripts/ready-check.sh" 2>&1) && rc=0 || rc=$?
t "deployment-root compared with origin's main, not the local ref" 0 "^OK .*deployment-root Synced" \
  '! grep -q "^FAIL" <<<"$out"' '! grep -q SENTINEL-deploy-token <<<"$out"'
D="$T/repo"

W="$T/secret"; ready "$W"; run
t "no secret in outputs.json" 0 "^OK " '[ -f "$(OUT)" ]' '! grep -q "$SECRET" "$(OUT)"' \
  '! grep -rq "$SECRET" "$D/.install"'

W="$T/waiting"; ready "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app limitador-redis Synced Progressing)]}" > "$W/hub/apps.json"; rm -f "$(OUT)"; run
t "an Application waiting for a site: FAIL" 1 "^FAIL .*limitador-redis" '[ ! -f "$(OUT)" ]'

W="$T/notoken"; ready "$W"; mv "$D/.config/provider-admin-token" "$T/token.bak"; run
mv "$T/token.bak" "$D/.config/provider-admin-token"
t "no provider-admin token: WARN, not FAIL" 0 "^WARN .*provider-admin-token" '[ ! -f "$W/curl.log" ] || ! grep -q ai_grid.v1 "$W/curl.log"'

echo "ready-check tests: $((total-fails)) ok, $fails failed"; exit "$fails"
