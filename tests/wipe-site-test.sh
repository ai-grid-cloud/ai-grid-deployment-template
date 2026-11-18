#!/usr/bin/env bash
# Tests for scripts/wipe-site.sh and scripts/detach-site.sh against a stub oc.
# Nothing here reaches a cluster.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
D="$T/deploy"; W="$T/world"; mkdir -p "$T/bin" "$D/.config/hub" "$D/.config/site-c" "$W"
cp -R "$SRC/scripts" "$D/"; touch "$D/.config/hub/kubeconfig" "$D/.config/site-c/kubeconfig"
cat > "$D/clusters.yaml" <<'EOF'
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {api: "https://api.hub.example.com:6443"}
sites:
  - {name: site-c, api: "https://api.site.example.com:6443"}
EOF
for t in kubectl jq; do ln -s "$(command -v "$t")" "$T/bin/$t"; done

# Stub oc. Each cluster is named by its login's directory (.config/NAME/kubeconfig);
# its world is $STUB/NAME.* files. Writes go to $STUB/writes; a delete of a
# namespace or the Klusterlet removes it from the world unless NAME.stuck exists.
cat > "$T/bin/oc" <<'STUB'
#!/usr/bin/env bash
kc="${KUBECONFIG:-}"; args=()
while [ $# -gt 0 ]; do case "$1" in --kubeconfig) kc=$2; shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"; c=$(basename "$(dirname "$kc")"); w="$STUB/$c"
case "$*" in
  "whoami") echo admin ;;
  "get managedcluster") [ -f "$w.hub" ] ;;
  get\ managedcluster\ *) grep -qx "$3" "$w.managed" 2>/dev/null ;;
  get\ ns\ *) grep -qx "$3" "$w.ns" 2>/dev/null ;;
  "get klusterlets.operator.open-cluster-management.io klusterlet -o name") [ -f "$w.klusterlet" ] && echo klusterlet.operator.open-cluster-management.io/klusterlet ;;
  "get appliedmanifestworks.work.open-cluster-management.io -o name") cat "$w.amws" 2>/dev/null ;;
  "get deployments.apps -n open-cluster-management -o name") [ ! -f "$w.ocm-error" ] || { echo "error: forbidden" >&2; exit 1; }
    cat "$w.ocm-deploys" 2>/dev/null ;;
  "get submariners.submariner.io -A --no-headers"*|"get servicediscoveries.submariner.io -A --no-headers"*) cat "$w.subcrs" 2>/dev/null ;;
  "api-resources --api-group=submariner.io --verbs=delete -o name") cat "$w.subkinds" 2>/dev/null ;;
  get\ *.submariner.io\ -A\ --no-headers*) cat "$w.subobjs" 2>/dev/null ;;
  "get deployment submariner-operator -n submariner-operator") [ -f "$w.subop" ] ;;
  "get nodes -l submariner.io/gateway -o name") cat "$w.gateways" 2>/dev/null ;;
  "api-resources --api-group=postgresql.cnpg.io -o name") [ -f "$w.dbclusters" ] || [ -f "$w.cnpg" ] && echo clusters.postgresql.cnpg.io; true ;;
  "get clusters.postgresql.cnpg.io -n maas-db -o jsonpath="*) [ ! -f "$w.dberror" ] || { echo "error: the server is currently unable to handle the request" >&2; exit 1; }
    cat "$w.dbclusters" 2>/dev/null; true ;;
  "get applications.argoproj.io -A -o jsonpath="*) cat "$w.apps" 2>/dev/null ;;
  "get clusters.postgresql.cnpg.io -n maas-db -o name") sed 's#|.*##; s#^#cluster.postgresql.cnpg.io/#' "$w.dbclusters" 2>/dev/null ;;
  "get persistentvolumeclaims -n maas-db -o name") cat "$w.pvcs" 2>/dev/null ;;
  get\ clusterpolicies.nvidia.com\ -A\ -o\ jsonpath=*|get\ nodefeaturediscoveries.nfd.openshift.io\ -A\ -o\ jsonpath=*|get\ clusterissuers.cert-manager.io\ -A\ -o\ jsonpath=*)
    cat "$w.track.$2" 2>/dev/null ;;
  delete\ *|patch\ *|label\ *|annotate\ *)
    echo "WRITE: $c $*" >> "$STUB/writes"
    if [ "$1" = delete ] && [ ! -f "$w.stuck" ]; then
      case "$2" in
        ns) grep -vx "$3" "$w.ns" > "$w.ns.new" 2>/dev/null; mv "$w.ns.new" "$w.ns" ;;
        # The klusterlet operator removes the agent with its Klusterlet.
        submariners.submariner.io) rm -f "$w.subcrs" ;;
        cluster.postgresql.cnpg.io/*) rm -f "$w.dbclusters" ;;
        klusterlets.operator.open-cluster-management.io) rm -f "$w.klusterlet"
          grep -v '^open-cluster-management-agent' "$w.ns" > "$w.ns.new" 2>/dev/null; mv "$w.ns.new" "$w.ns" ;;
      esac
    fi ;;
  get*" -o "*|get*--no-headers*|api-resources*) exit 0 ;;   # an empty list
  *) exit 1 ;;                                               # not found
esac
STUB
# Waits don't wait: the stub world changes only when the scripts write.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/oc" "$T/bin/sleep"

world() { # a detached site with nothing left on it
  rm -f "$W"/hub.* "$W"/site-c.* "$W/writes"; : > "$W/site-c.ns"
}
run() { # script args...
  local s=$1; shift
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" STUB="$W" DETACH_POLL=0 DETACH_TIMEOUT=5 WIPE_PROTECT_NAMESPACES="${WPN:-}" bash "$D/scripts/$s" "$@" 2>&1
}
t() { # name want_rc expect_grep script args...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1)); out=$(run "$@") && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out" | tail -15; fi
}
wrote() { # name expect_grep: the writes log has a line matching
  total=$((total+1))
  if grep -qE -- "$2" "$W/writes" 2>/dev/null; then echo "   ok   $1"
  else fails=$((fails+1)); echo "   FAIL $1; writes:"; cat "$W/writes" 2>/dev/null || true; fi
}
no_writes() { # name
  total=$((total+1))
  if [ ! -s "$W/writes" ]; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1: $(cat "$W/writes")"; fi
}
klusterlet_world() { # a site detached from a hub that's gone, with the klusterlet operator left
  world; printf 'open-cluster-management\n' > "$W/site-c.ns"; echo deployment.apps/klusterlet > "$W/site-c.ocm-deploys"
  printf 'appliedmanifestwork.work.open-cluster-management.io/0123abcd-addon-submariner-deploy-0\n' > "$W/site-c.amws"
}

# wipe-site.sh: refusals
world; echo open-cluster-management-agent > "$W/site-c.ns"
t "the wipe refuses while a hub manages the site, and names site-detach" 1 "still managed by a hub: .*make site-detach" wipe-site.sh --site site-c
no_writes "  ... and writes nothing"
world; touch "$W/site-c.hub"; t "the wipe refuses on an ACM hub" 1 "is an ACM hub" wipe-site.sh --site site-c
world; WPN=redhat-ods-applications t "the wipe refuses a protected namespace on its list" 1 "namespace redhat-ods-applications is protected" wipe-site.sh --site site-c
no_writes "  ... and writes nothing"

# wipe-site.sh: the klusterlet operator an old hub leaves (F13)
klusterlet_world; t "the dry run lists the klusterlet operator and its lease" 0 \
  "would delete: deployment.apps klusterlet -n open-cluster-management" wipe-site.sh --site site-c --dry-run
klusterlet_world; t "  ... the lease" 0 "would delete: lease.coordination.k8s.io klusterlet-lock -n open-cluster-management" wipe-site.sh --site site-c --dry-run
klusterlet_world; t "  ... the namespace, when nothing else runs there" 0 "would delete: ns open-cluster-management$" wipe-site.sh --site site-c --dry-run
klusterlet_world; t "  ... the old hub's AppliedManifestWorks" 0 \
  "would delete without finalizers: appliedmanifestwork.work.open-cluster-management.io/0123abcd-addon-submariner-deploy-0" wipe-site.sh --site site-c --dry-run
klusterlet_world; run wipe-site.sh --site site-c --dry-run >/dev/null; no_writes "  ... and the dry run writes nothing"
klusterlet_world; run wipe-site.sh --site site-c >/dev/null
wrote "the wipe deletes the klusterlet Deployment" "delete deployment.apps klusterlet -n open-cluster-management"
wrote "  ... its lease" "delete lease.coordination.k8s.io klusterlet-lock -n open-cluster-management"
wrote "  ... the AppliedManifestWorks' finalizers, then them" "patch appliedmanifestwork.work.open-cluster-management.io/0123abcd-addon-submariner-deploy-0 .*finalizers"
wrote "  ... the namespace" "delete ns open-cluster-management"
klusterlet_world; printf 'deployment.apps/klusterlet\ndeployment.apps/something-else\n' > "$W/site-c.ocm-deploys"
t "the wipe keeps open-cluster-management when something else runs there" 0 "kept namespace open-cluster-management: it also runs deployment.apps/something-else" \
  wipe-site.sh --site site-c --dry-run
klusterlet_world; touch "$W/site-c.klusterlet"; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
a=$(grep -n "would delete: klusterlets.operator.open-cluster-management.io klusterlet" <<<"$out" | cut -d: -f1 || true)
b=$(grep -n "would delete: deployment.apps klusterlet" <<<"$out" | cut -d: -f1 || true)
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "   ok   a Klusterlet left after the detach goes before its operator"
else fails=$((fails+1)); echo "   FAIL a Klusterlet left after the detach goes before its operator"; echo "$out" | grep -i klusterlet; fi
world; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
if ! grep -q "would delete.*klusterlet" <<<"$out"; then echo "   ok   a site with no klusterlet operator plans none"
else fails=$((fails+1)); echo "   FAIL a site with no klusterlet operator plans none"; echo "$out" | grep klusterlet; fi

# detach-site.sh (F13)
agent_world() { # a site whose old hub is gone: Klusterlet and agent namespaces still there
  world; touch "$W/site-c.klusterlet"
  printf 'open-cluster-management\nopen-cluster-management-agent\nopen-cluster-management-agent-addon\n' > "$W/site-c.ns"
  printf 'appliedmanifestwork.work.open-cluster-management.io/0123abcd-klusterlet\n' > "$W/site-c.amws"
}
agent_world; t "the detach dry run names the Klusterlet" 0 "would delete: klusterlets.operator.open-cluster-management.io klusterlet" detach-site.sh --site site-c --dry-run
agent_world; t "  ... and the AppliedManifestWorks" 0 "would delete without finalizers: appliedmanifestwork.work.open-cluster-management.io/0123abcd-klusterlet" detach-site.sh --site site-c --dry-run
agent_world; run detach-site.sh --site site-c --dry-run >/dev/null; no_writes "  ... and writes nothing"
agent_world; t "the detach deletes the Klusterlet and waits for the agent namespaces" 0 "^Detached:" detach-site.sh --site site-c
wrote "  ... deleted the Klusterlet" "delete klusterlets.operator.open-cluster-management.io klusterlet"
wrote "  ... then the AppliedManifestWorks" "delete appliedmanifestwork.work.open-cluster-management.io/0123abcd-klusterlet"
agent_world; touch "$W/site-c.stuck"
t "the detach stops with a clear error when the agent doesn't go" 1 \
  "still present after 0s: Klusterlet klusterlet, namespace open-cluster-management-agent, namespace open-cluster-management-agent-addon" detach-site.sh --site site-c --timeout 0
total=$((total+1))
if ! grep -q appliedmanifestwork "$W/writes"; then echo "   ok   ... and keeps the AppliedManifestWorks until the agent is gone"
else fails=$((fails+1)); echo "   FAIL ... and keeps the AppliedManifestWorks until the agent is gone"; fi
agent_world; rm "$W/site-c.klusterlet"; t "with no Klusterlet, the detach deletes the agent namespaces itself" 0 "^Detached:" detach-site.sh --site site-c
wrote "  ... the agent namespace" "delete ns open-cluster-management-agent "
world; t "a site no hub manages has nothing to detach" 0 "Nothing to do" detach-site.sh --site site-c
agent_world; echo site-c > "$W/hub.managed"
t "the detach refuses a site that is a ManagedCluster on your hub" 1 "site-c is a ManagedCluster on your hub hub" detach-site.sh --site site-c
no_writes "  ... and writes nothing"
agent_world; touch "$W/site-c.hub"; t "the detach refuses on an ACM hub" 1 "is an ACM hub" detach-site.sh --site site-c
agent_world; t "a bad timeout is refused" 1 "--timeout takes a number" detach-site.sh --site site-c --timeout soon

# wipe-site.sh: Submariner an old hub's add-on left (F14)
sub_world() { # a detached site with Submariner, its operator running, Globalnet objects and two gateway nodes
  world; printf 'submariner-operator\n' > "$W/site-c.ns"; touch "$W/site-c.subop"
  echo "submariner-operator submariner" > "$W/site-c.subcrs"
  printf 'submariners.submariner.io\nservicediscoveries.submariner.io\nclusterglobalegressips.submariner.io\nglobalingressips.submariner.io\n' > "$W/site-c.subkinds"
  echo "<none> cluster-egress.submariner.io" > "$W/site-c.subobjs"
  printf 'node/worker-a\nnode/worker-b\n' > "$W/site-c.gateways"
}
sub_world; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
a=$(grep -n "would delete: submariners.submariner.io submariner -n submariner-operator" <<<"$out" | head -1 | cut -d: -f1 || true)
b=$(grep -n "would delete: subscriptions.operators.coreos.com\|== 6\." <<<"$out" | head -1 | cut -d: -f1 || true)
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "   ok   the dry run lists the Submariner CR before the operators go"
else fails=$((fails+1)); echo "   FAIL the dry run lists the Submariner CR before the operators go"; echo "$out" | grep -i -e submariner -e "== "; fi
sub_world; t "  ... Globalnet's cluster-scoped objects, without finalizers" 0 \
  "would delete without finalizers: clusterglobalegressips.submariner.io cluster-egress.submariner.io$" wipe-site.sh --site site-c --dry-run
sub_world; t "  ... the namespace submariner-operator" 0 "would delete: ns submariner-operator$" wipe-site.sh --site site-c --dry-run
sub_world; t "  ... the gateway node labels" 0 "would remove label submariner.io/gateway from: node/worker-b" wipe-site.sh --site site-c --dry-run
sub_world; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
a=$(grep -n "would delete: ns submariner-operator" <<<"$out" | cut -d: -f1 || true); b=$(grep -n "would remove label submariner.io/gateway" <<<"$out" | head -1 | cut -d: -f1 || true)
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "   ok     ... the labels last, after the namespace"
else fails=$((fails+1)); echo "   FAIL   ... the labels last, after the namespace"; fi
sub_world; run wipe-site.sh --site site-c --dry-run >/dev/null; no_writes "  ... and the dry run writes nothing"
sub_world; run wipe-site.sh --site site-c >/dev/null
wrote "the wipe deletes the Submariner CR" "delete submariners.submariner.io submariner -n submariner-operator"
wrote "  ... Globalnet's objects, finalizers first" "patch clusterglobalegressips.submariner.io cluster-egress.submariner.io .*finalizers"
wrote "  ... the namespace" "delete ns submariner-operator"
wrote "  ... the gateway labels" "label node/worker-a submariner.io/gateway-"
sub_world; rm "$W/site-c.subop"; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
if grep -q "would delete without finalizers: submariners.submariner.io submariner -n submariner-operator" <<<"$out"; then
  echo "   ok   with its operator gone, the Submariner CR goes without its finalizer"
else fails=$((fails+1)); echo "   FAIL with its operator gone, the Submariner CR goes without its finalizer"; echo "$out" | grep -i submariner; fi
sub_world; touch "$W/site-c.stuck"; out=$(run wipe-site.sh --site site-c 2>&1 || true); total=$((total+1))
if grep -q "kept the submariner.io/gateway node labels" <<<"$out" && ! grep -q "label node/" "$W/writes"; then
  echo "   ok   the labels stay while namespace submariner-operator is still there"
else fails=$((fails+1)); echo "   FAIL the labels stay while namespace submariner-operator is still there"; fi

# wipe-site.sh: the maas-db read replica of an old primary
db_world() { world; echo maas-db > "$W/site-c.ns"; echo "maas-read|true" > "$W/site-c.dbclusters"; echo persistentvolumeclaim/maas-read-1 > "$W/site-c.pvcs"; }
db_world; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
a=$(grep -n "would delete: cluster.postgresql.cnpg.io/maas-read -n maas-db" <<<"$out" | cut -d: -f1 || true)
b=$(grep -n "would delete: persistentvolumeclaim/maas-read-1 -n maas-db" <<<"$out" | cut -d: -f1 || true)
c=$(grep -n "would delete: ns maas-db$" <<<"$out" | cut -d: -f1 || true)
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then echo "   ok   the dry run lists the replica, then its volume, then namespace maas-db"
else fails=$((fails+1)); echo "   FAIL the dry run lists the replica, then its volume, then namespace maas-db"; echo "$out" | grep maas; fi
db_world; run wipe-site.sh --site site-c --dry-run >/dev/null; no_writes "  ... and the dry run writes nothing"
db_world; run wipe-site.sh --site site-c >/dev/null
wrote "the wipe deletes the replica" "delete cluster.postgresql.cnpg.io/maas-read -n maas-db"
wrote "  ... its volume" "delete persistentvolumeclaim/maas-read-1 -n maas-db"
wrote "  ... and namespace maas-db" "delete ns maas-db"
db_world; echo "maas-db|" > "$W/site-c.dbclusters"
t "the wipe refuses a maas-db primary, and names the flag" 1 "isn't a read replica .*maas-db.*--wipe-maas-db-primary" wipe-site.sh --site site-c --dry-run
no_writes "  ... and writes nothing"
db_world; echo "maas-db|false" > "$W/site-c.dbclusters"
t "  ... also with replica.enabled false" 1 "isn't a read replica" wipe-site.sh --site site-c --dry-run
db_world; echo "maas-db|" > "$W/site-c.dbclusters"
t "  ... unless --wipe-maas-db-primary is given" 0 "would delete: cluster.postgresql.cnpg.io/maas-db -n maas-db" wipe-site.sh --site site-c --dry-run --wipe-maas-db-primary

# wipe-site.sh: stale Argo CD tracking on the platform's objects (step 0)
track_world() {
  world
  echo "|gpu-cluster-policy|rhoai-site-c-1a2b|rhoai-site-c-1a2b:nvidia.com/ClusterPolicy:/gpu-cluster-policy|" > "$W/site-c.track.clusterpolicies.nvidia.com"
  echo "openshift-nfd|nfd-instance||rhoai-site-c-1a2b:nfd.openshift.io/NodeFeatureDiscovery:openshift-nfd/nfd-instance|" > "$W/site-c.track.nodefeaturediscoveries.nfd.openshift.io"
  printf '|letsencrypt|my-release||Helm\n|plain|||\n' > "$W/site-c.track.clusterissuers.cert-manager.io"
}
track_world; t "the dry run lists the ClusterPolicy's tracking label" 0 \
  "would remove label app.kubernetes.io/instance=rhoai-site-c-1a2b from: clusterpolicies.nvidia.com gpu-cluster-policy$" wipe-site.sh --site site-c --dry-run
track_world; t "  ... and its tracking annotation" 0 "would remove annotation argocd.argoproj.io/tracking-id from: clusterpolicies.nvidia.com gpu-cluster-policy$" wipe-site.sh --site site-c --dry-run
track_world; t "  ... the NodeFeatureDiscovery's, in its protected namespace" 0 \
  "would remove annotation argocd.argoproj.io/tracking-id from: nodefeaturediscoveries.nfd.openshift.io nfd-instance -n openshift-nfd" wipe-site.sh --site site-c --dry-run
track_world; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
if ! grep -q "clusterissuers" <<<"$out"; then echo "   ok     ... not Helm's own instance label, nor an untracked ClusterIssuer"
else fails=$((fails+1)); echo "   FAIL   ... not Helm's own instance label, nor an untracked ClusterIssuer"; grep clusterissuers <<<"$out"; fi
track_world; run wipe-site.sh --site site-c --dry-run >/dev/null; no_writes "  ... and the dry run writes nothing"
track_world; run wipe-site.sh --site site-c >/dev/null
wrote "the wipe removes only the tracking label" "label clusterpolicies.nvidia.com gpu-cluster-policy app.kubernetes.io/instance-$"
wrote "  ... and the tracking annotation" "annotate nodefeaturediscoveries.nfd.openshift.io nfd-instance -n openshift-nfd argocd.argoproj.io/tracking-id-$"
total=$((total+1))
if ! grep -E "(delete|patch) (clusterpolicies|nodefeaturediscoveries|clusterissuers)" "$W/writes" >/dev/null; then echo "   ok     ... and never deletes or patches those objects"
else fails=$((fails+1)); echo "   FAIL   ... and never deletes or patches those objects"; fi

# Review follow-ups
klusterlet_world; touch "$W/site-c.ocm-error"
t "the wipe stops when it can't list open-cluster-management's Deployments" 1 "can't list the Deployments in namespace open-cluster-management: error: forbidden" wipe-site.sh --site site-c --dry-run
klusterlet_world; touch "$W/site-c.klusterlet" "$W/site-c.stuck"; run wipe-site.sh --site site-c >/dev/null 2>&1 || true
wrote "a Klusterlet still there once its operator is gone loses its finalizers" "patch klusterlets.operator.open-cluster-management.io klusterlet .*finalizers"
db_world; touch "$W/site-c.dberror"
t "the maas-db primary check fails closed when the databases can't be listed" 1 "can't list the databases in namespace maas-db.*unable to handle" wipe-site.sh --site site-c --dry-run
no_writes "  ... and writes nothing"
world; touch "$W/site-c.cnpg"; t "  ... a cluster with CloudNativePG but no maas-db database passes" 0 "dry run: nothing deleted" wipe-site.sh --site site-c --dry-run
track_world; echo "rhoai-site-c-1a2b openshift-gitops_rhoai-site-c-1a2b " > "$W/site-c.apps"
t "tracking that names an Application on the site itself is kept" 0 \
  "kept \(tracked by this cluster's own Argo CD Application rhoai-site-c-1a2b\): clusterpolicies.nvidia.com gpu-cluster-policy" wipe-site.sh --site site-c --dry-run
track_world; echo "rhoai-site-c-1a2b openshift-gitops_rhoai-site-c-1a2b " > "$W/site-c.apps"; out=$(run wipe-site.sh --site site-c --dry-run); total=$((total+1))
if ! grep -q "would remove .* from: \(clusterpolicies\|nodefeaturediscoveries\)" <<<"$out"; then echo "   ok     ... for both objects it tracks"
else fails=$((fails+1)); echo "   FAIL   ... for both objects it tracks"; grep "would remove" <<<"$out"; fi
track_world; echo "|issuer|rhoai-site-c-1a2b|rhoai-site-c-1a2b:cert-manager.io/ClusterIssuer:/issuer|Helm" > "$W/site-c.track.clusterissuers.cert-manager.io"
t "Helm's instance label goes when the tracking-id names it as the Application" 0 \
  "would remove label app.kubernetes.io/instance=rhoai-site-c-1a2b from: clusterissuers.cert-manager.io issuer$" wipe-site.sh --site site-c --dry-run

agent_world; mv "$D/.config/hub/kubeconfig" "$T/hub-kubeconfig"
t "the detach refuses when it can't check your hub" 1 "can't check whether your hub hub manages site-c: run make login NAME=hub" detach-site.sh --site site-c
no_writes "  ... and writes nothing"
mv "$T/hub-kubeconfig" "$D/.config/hub/kubeconfig"
agent_world; t "with --kubeconfig, the detach warns that it skipped the hub check" 0 "warning: with --kubeconfig, this doesn't check" \
  detach-site.sh --kubeconfig "$D/.config/site-c/kubeconfig" --dry-run
no_writes "  ... and the dry run writes nothing"
agent_world; t "with --kubeconfig, the detach deletes the Klusterlet" 0 "^Detached:" detach-site.sh --kubeconfig "$D/.config/site-c/kubeconfig"
wrote "  ... on that cluster" "^WRITE: site-c delete klusterlets.operator.open-cluster-management.io klusterlet"
world; t "--timeout with no value prints the usage" 1 "Usage: detach-site.sh" detach-site.sh --timeout
world; t "--site with no value prints the usage" 1 "Usage: detach-site.sh" detach-site.sh --site

echo "wipe-site tests: $((total-fails)) ok, $fails failed"; exit "$fails"
