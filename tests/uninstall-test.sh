#!/usr/bin/env bash
# Tests for scripts/uninstall.sh's safety checks and dry run, against a stub oc
# and a repository copy with a clusters file. Nothing here reaches a cluster.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
D="$T/deploy"; W="$T/world"; mkdir -p "$T/bin" "$D/.config/hub" "$D/.config/site-b" "$W"
cp -R "$SRC/scripts" "$D/"; touch "$D/.config/hub/kubeconfig" "$D/.config/site-b/kubeconfig"
cat > "$D/clusters" <<'EOF'
hub      hub       -        https://api.hub.example.com:6443
site-b   combined  us-east  https://api.site.example.com:6443
EOF
cp tests/fixtures/uninstall-applications.json "$W/apps.json"

# Stub oc. Each cluster is named by its login's directory (.config/NAME/kubeconfig),
# from --kubeconfig or KUBECONFIG; its world is $STUB/NAME.* files.
cat > "$T/bin/oc" <<'STUB'
#!/usr/bin/env bash
kc="${KUBECONFIG:-}"; args=()
while [ $# -gt 0 ]; do case "$1" in --kubeconfig) kc=$2; shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"; c=$(basename "$(dirname "$kc")"); w="$STUB/$c"
echo "oc $c $*" >> "$STUB/calls"
case "$*" in
  "whoami") [ -f "$w.expired" ] && exit 1; echo admin ;;
  "whoami --show-server") cat "$w.api" ;;
  "auth whoami -o jsonpath="*) cat "$w.groups" 2>/dev/null ;;
  "auth can-i * * --all-namespaces") cat "$w.can-i" ;;
  "get oauth cluster -o jsonpath="*) echo "rhbk" ;;
  "get clusterrolebindings -o json") cat "$w.crbs" ;;
  "get applications.argoproj.io -n openshift-gitops -o json") cat "$STUB/apps.json" ;;
  "get managedclusters -o jsonpath="*) cat "$w.managed" 2>/dev/null ;;
  "get managedcluster local-cluster -o jsonpath="*) echo "" ;;
  "get managedcluster site-b") [ -s "$w.managed" ] && grep -qx site-b "$w.managed" ;;
  "get klusterlet klusterlet -o jsonpath="*) cat "$w.klusterlet" 2>/dev/null ;;
  "get klusterlet klusterlet") [ -s "$w.klusterlet" ] ;;
  get\ ns\ *) grep -qx "$3" "$w.ns" 2>/dev/null ;;
  "get validatingwebhookconfigurations -o json") cat "$w.vwh" 2>/dev/null ;;
  "get clusterimagesets.hive.openshift.io -o name") cat "$w.cis" 2>/dev/null ;;
  "get configmaps cluster-monitoring-config -n openshift-monitoring -o name") [ -s "$w.cmc" ] && echo configmap/cluster-monitoring-config ;;
  "get configmap/cluster-monitoring-config -n openshift-monitoring -o jsonpath="*) cat "$w.cmc" ;;
  "get consoleplugins.console.openshift.io -o jsonpath="*) cat "$w.plugins" 2>/dev/null ;;
  "get consoles.operator.openshift.io cluster -o jsonpath="*) cat "$w.enabled" 2>/dev/null ;;
  get\ consoleplugins.console.openshift.io\ *) grep -qx "$3" "$w.plugin-objects" 2>/dev/null ;;
  get\ applicationsets.argoproj.io*) echo "applicationset.argoproj.io/apps" ;;
  get\ applications.argoproj.io\ -n\ openshift-gitops\ -o\ name) echo "application.argoproj.io/acm" ;;
  get\ secrets\ -n\ openshift-gitops*) echo '{"items":[]}' ;;
  delete*|patch*|label*|annotate*|apply*|create*|replace*|scale*) echo "WRITE: $c $*" >> "$STUB/writes" ;;
  get*" -o "*|get*--no-headers*) exit 0 ;;   # an empty list
  *) exit 1 ;;                                # not found
esac
STUB
chmod +x "$T/bin/oc"

world() { # a hub and a site that pass every check
  rm -f "$W"/hub.* "$W"/site-b.* "$W/calls" "$W/writes"
  echo https://api.hub.example.com:6443 > "$W/hub.api"; echo https://api.site.example.com:6443 > "$W/site-b.api"
  for c in hub site-b; do
    echo yes > "$W/$c.can-i"; echo "system:authenticated" > "$W/$c.groups"
    echo '{"items":[{"metadata":{"name":"cluster-admin-0"},"roleRef":{"name":"cluster-admin"},"subjects":[{"kind":"User","name":"admin"}]}]}' > "$W/$c.crbs"
  done
  echo site-b > "$W/hub.managed"; echo site-b > "$W/site-b.klusterlet"
}
run() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" STUB="$W" WIPE_PROTECT_NAMESPACES="${WPN:-}" bash "$D/scripts/uninstall.sh" "$@" 2>&1; }
t() { # name want_rc expect_grep args...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1)); out=$(run "$@") && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out" | tail -15; fi
}
no_writes() { # name args...: the run succeeds, says it deleted nothing, and the stub logged no write
  local name=$1 out; shift; total=$((total+1)); out=$(run "$@" || true)
  if [ ! -s "$W/writes" ] && grep -q "dry run: nothing deleted" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name: $(cat "$W/writes" 2>/dev/null)"; echo "$out" | tail -5; fi
}

# Arguments and the clusters file
world; t "no step is refused" 1 "usage: uninstall.sh" 
world; t "a site step needs a name" 1 "usage: uninstall.sh site NAME" site --dry-run
world; t "an unknown site is refused" 1 "no cluster site-z in" site site-z --dry-run
world; t "the hub as a site is refused" 1 "hub is the hub" site hub --dry-run
world; t "local-cluster as a site is refused" 1 "isn't supported yet" site local-cluster --dry-run
world; t "an unknown option is refused" 1 "unknown argument: --hub-kubeconfig" hub --hub-kubeconfig x

# Logins
world; rm "$D/.config/site-b/kubeconfig"; t "a site with no login is refused" 1 "no login for site-b: run make login NAME=site-b" site site-b --dry-run
touch "$D/.config/site-b/kubeconfig"
world; touch "$W/hub.expired"; t "an expired hub login is refused" 1 "hub: login expired" hub --dry-run
world; echo https://api.other.example.com:6443 > "$W/hub.api"; t "a hub login for the wrong API server is refused" 1 "hub: the login is for https://api.other.example.com:6443, not https://api.hub.example.com:6443" hub --dry-run
world; echo https://api.hub.example.com:6443 > "$W/site-b.api"; t "a site login for the wrong API server is refused" 1 "site-b: the login is for https://api.hub.example.com:6443, not https://api.site.example.com:6443" site site-b --dry-run
world; echo https://api.hub.example.com:6443/ > "$W/hub.api"; t "a trailing slash on the server is the same server" 0 "dry run: nothing deleted" hub --dry-run
world; echo no > "$W/hub.can-i"; t "a hub login without cluster-admin is refused" 1 "hub: admin isn't cluster-admin" hub --dry-run
world; echo no > "$W/site-b.can-i"; t "a site login without cluster-admin is refused" 1 "site-b: admin isn't cluster-admin" site site-b --dry-run
world; t "the sign-in's identity provider is a warning, not a refusal" 0 "warning: hub signs in through: rhbk" hub --dry-run
world; echo '{"items":[{"metadata":{"name":"cluster-admin-admin"},"roleRef":{"name":"cluster-admin"},"subjects":[{"kind":"User","name":"admin"}]}]}' > "$W/hub.crbs"
t "refused when the login's only binding is one it deletes" 1 "only through objects the uninstall deletes \(cluster-admin-admin\)" hub --dry-run
world; echo "system:authenticated cluster-admins" > "$W/hub.groups"
echo '{"items":[{"metadata":{"name":"cluster-admin-admin"},"roleRef":{"name":"cluster-admin"},"subjects":[{"kind":"Group","name":"cluster-admins"}]}]}' > "$W/hub.crbs"
t "refused when the login's group binding is one it deletes" 1 "only through objects the uninstall deletes \(cluster-admin-admin\)" hub --dry-run
world; echo '{"items":[{"metadata":{"name":"cluster-admin-admin"},"roleRef":{"name":"cluster-admin"},"subjects":[{"kind":"User","name":"admin"}]},{"metadata":{"name":"cluster-admins"},"roleRef":{"name":"cluster-admin"},"subjects":[{"kind":"Group","name":"system:cluster-admins"}]}]}' > "$W/hub.crbs"
echo "system:authenticated system:cluster-admins" > "$W/hub.groups"
t "allowed when another binding keeps the login cluster-admin" 0 "dry run: nothing deleted" hub --dry-run

# The hub step and the site step
world; t "the hub refuses while sites are managed" 1 "sites are still managed .*: site-b$" hub
total=$((total+1)); if [ ! -s "$W/writes" ]; then echo "   ok   the refused hub step wrote nothing"; else fails=$((fails+1)); echo "   FAIL the refused hub step wrote: $(cat "$W/writes")"; fi
world; t "the hub dry run warns about managed sites and lists the plan" 0 "would delete: MultiClusterHub" hub --dry-run
world; no_writes "the hub dry run deletes nothing" hub --dry-run
world; printf 'ai-tenants\nopen-cluster-management\n' > "$W/site-b.ns"; no_writes "the site dry run deletes nothing" site site-b --dry-run
world; echo site-a > "$W/site-b.klusterlet"; t "a site whose klusterlet names another cluster is refused" 1 "klusterlet says it's site-a" site site-b --dry-run
world; t "the site dry run plans the detach, then the site's objects" 0 "would delete: managedcluster site-b" site site-b --dry-run
world; t "the site dry run runs wipe-site.sh" 0 "== 1. models" site site-b --dry-run
world; t "a cluster-scoped object is deleted without a namespace" 0 "would delete: Namespace redhat-ods-applications\$" site site-b --dry-run
world; t "a namespaced object is deleted in its namespace" 0 "would delete: Cluster.v1.postgresql.cnpg.io maas-db -n maas-db" hub --dry-run
world; printf 'ai-tenants\nopen-cluster-management\n' > "$W/site-b.ns"; out=$(run site site-b --dry-run); total=$((total+1))
k=$(grep -n "would delete: klusterlet klusterlet" <<<"$out" | cut -d: -f1); n=$(grep -n "would delete: ns open-cluster-management\$" <<<"$out" | cut -d: -f1)
if [ -n "$k" ] && [ -n "$n" ] && [ "$k" -lt "$n" ]; then echo "   ok   the site's leftover namespaces are swept, after its Klusterlet"
else fails=$((fails+1)); echo "   FAIL the site's leftover namespaces are swept, after its Klusterlet"; fi
world; printf 'ai-tenants\n' > "$W/site-b.ns"; out=$(run site site-b --dry-run); total=$((total+1))
if grep -q "would delete: ns ai-tenants" <<<"$out" && ! grep -q "would delete: ns redhat-ai-gateway-infra" <<<"$out"; then echo "   ok   only leftover namespaces that exist are swept"
else fails=$((fails+1)); echo "   FAIL only leftover namespaces that exist are swept"; fi
world; printf 'ai-tenants\n' > "$W/site-b.ns"; WPN=ai-tenants t "a deployment's protected namespace isn't swept" 0 "kept \(protected namespace\): ai-tenants" site site-b --dry-run
world; printf 'default-broker\n' > "$W/hub.ns"; t "the hub's leftover namespaces are swept" 0 "would delete: ns default-broker" hub --dry-run
world; printf 'custom-resources\tCluster.v1.postgresql.cnpg.io\tmaas-db\tsaved-plan-object\n' > "$T/plan.tsv"
t "a saved plan file is reused" 0 "would delete: Cluster.v1.postgresql.cnpg.io saved-plan-object -n maas-db" site site-b --dry-run --plan-file "$T/plan.tsv"
world; rm -f "$T/plan2.tsv"; run site site-b --dry-run --plan-file "$T/plan2.tsv" >/dev/null || true; total=$((total+1))
if [ ! -e "$T/plan2.tsv" ]; then echo "   ok   a dry run doesn't write the plan file"; else fails=$((fails+1)); echo "   FAIL a dry run wrote the plan file"; fi
world; t "the site's Submariner add-on goes before the detach" 0 "would delete: managedclusteraddons.addon.open-cluster-management.io submariner -n site-b" site site-b --dry-run
world; printf 'acm\tMultiClusterHub.v1.operator.open-cluster-management.io\topen-cluster-management\tsaved-mch\n' > "$T/hubplan.tsv"
t "the hub step reuses a saved plan file" 0 "would delete: MultiClusterHub.v1.operator.open-cluster-management.io saved-mch" hub --dry-run --plan-file "$T/hubplan.tsv"
world; echo '{"items":[{"metadata":{"name":"dangling"},"webhooks":[{"clientConfig":{"service":{"namespace":"gone","name":"svc"}}}]},{"metadata":{"name":"alive"},"webhooks":[{"clientConfig":{"service":{"namespace":"keycloak","name":"svc"}}}]}]}' > "$W/hub.vwh"; echo keycloak > "$W/hub.ns"
out=$(run hub --dry-run); total=$((total+1))
if grep -q "would delete: validatingwebhookconfigurations dangling" <<<"$out" && ! grep -q "would delete: validatingwebhookconfigurations alive" <<<"$out"; then echo "   ok   only webhooks into deleted namespaces are dropped"
else fails=$((fails+1)); echo "   FAIL only webhooks into deleted namespaces are dropped"; fi
world; printf 'clusterimageset.hive.openshift.io/img4.20.0\n' > "$W/hub.cis"
t "listed leftovers are swept" 0 "would delete: clusterimageset.hive.openshift.io/img4.20.0" hub --dry-run
world; echo "cluster-monitoring-operator" > "$W/hub.cmc"
t "a platform's own cluster-monitoring-config is kept" 0 "kept \(not written by hypershift-operator-manager\): configmap/cluster-monitoring-config" hub --dry-run
world; echo "hypershift-operator-manager kubectl" > "$W/hub.cmc"
t "HyperShift's cluster-monitoring-config is deleted" 0 "would delete: configmap/cluster-monitoring-config -n openshift-monitoring" hub --dry-run
world; printf 'gone-plugin=kuadrant-system\n' > "$W/site-b.plugins"
t "a console plugin whose backend namespace is gone is deleted" 0 "would delete: consoleplugins.console.openshift.io gone-plugin" site site-b --dry-run
world; printf 'monitoring-plugin\nmissing-plugin\n' > "$W/hub.enabled"; echo monitoring-plugin > "$W/hub.plugin-objects"
t "an enabled plugin with no ConsolePlugin is disabled" 0 "console plugin missing-plugin has no ConsolePlugin" hub --dry-run
echo "uninstall tests: $((total-fails)) ok, $fails failed"; exit "$fails"
