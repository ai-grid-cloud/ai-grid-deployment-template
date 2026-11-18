#!/usr/bin/env bash
# Remove an AI Grid site's install (OpenShift AI, MaaS, the grid and their
# operators) so the cluster can join a new hub from scratch.
#
# Run it only after the site has left its old hub: on the old hub (labels
# removed, ManagedCluster deleted), or, when that hub is gone, with
# detach-site.sh (make site-detach) on the site.
#
# Order: models while KServe still
# runs; MaaS tenant objects before anything they need; the DSC, then
# its components, before the operator; the grid's cluster-scoped records
#; AI Grid gateways and their EnvoyFilters; operators; leftover
# webhooks; the old hub's klusterlet operator (left by a detach; while it runs it
# holds its lease, and a new hub's import can time out waiting for it);
# namespaces last.
#
# It removes the stateful leftovers that a new hub only adds to and never
# replaces: the old hub's AppliedManifestWorks, Submariner (its broker
# connection and Globalnet IPs), the maas-db read replica (CloudNativePG Cluster
# maas-read, which keeps replicating from the old primary), and Argo CD tracking
# on the platform's GPU and certificate objects.
#
# Never touched, whatever the lists below say: the platform's Keycloak
# (namespace keycloak, its operator, OAuth IdP rhbk), cert-manager, NFD, the GPU
# operator, ACME ClusterIssuers, and every openshift-*/kube-* namespace not
# listed below. The one exception: the Argo CD tracking label and annotation on
# ClusterPolicies, NodeFeatureDiscoveries and ClusterIssuers go (step 0), and
# nothing else on them changes. An install that once created them through
# per-site values left that tracking, and a new hub's Application of the same
# name then takes them for its own and prunes them (site-c, 2026-11-18).
# Cluster-wide pull secret and mirror changes stay: the new hub's prerequisites
# Policy manages them, and removing a mirror drains every node.
set -Eeuo pipefail

# Add your platform's own with WIPE_PROTECT_NAMESPACES and WIPE_PROTECT_PACKAGES
# (space-separated); the script stops if one of them is on a list below.
PROTECTED_NAMESPACES="keycloak cert-manager cert-manager-operator openshift-cert-manager-operator openshift-nfd nvidia-gpu-operator openshift-config openshift-authentication openshift-ingress default ${WIPE_PROTECT_NAMESPACES:-}"
PROTECTED_PACKAGES="rhbk-operator openshift-cert-manager-operator nfd gpu-operator-certified ${WIPE_PROTECT_PACKAGES:-}"

# Operators an AI Grid site's OpenShift AI install brings (package names).
OPERATOR_PACKAGES="submariner rhods-operator rhcl-operator authorino-operator dns-operator limitador-operator cluster-observability-operator leader-worker-set loki-operator opentelemetry-product tempo-product"
# API groups whose objects belong to the install (deleted in every namespace).
MAAS_GROUPS="maas.opendatahub.io aigateway.opendatahub.io inference.opendatahub.io"
GRID_GROUPS="grid.praxis.fast"
# Gateways in openshift-ingress that OpenShift AI and MaaS create.
GATEWAYS="data-science-gateway openshift-ai-inference maas-default-gateway"
# Namespaces the install creates.
NAMESPACES="ai-grid-internal-models kuadrant-system maas-db submariner-operator limitador-redis models-as-a-service odh-observability-webhook-probe redhat-ai-grid redhat-ods-applications redhat-ods-monitoring redhat-ods-operator openshift-cluster-observability-operator openshift-lws-operator openshift-opentelemetry-operator openshift-tempo-operator openshift-operators-redhat"
WEBHOOK_PATTERN='kserve|opendatahub|odh-|llminferenceservice'

usage() { echo "Usage: wipe-site.sh [--site NAME | --kubeconfig PATH] [--dry-run [--assume-detached]] [--wipe-maas-db-primary]  (default: the only site's login)"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kubeconfig="" name="" dry_run=false assume_detached=false wipe_primary=false
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --site) name="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    # For uninstall.sh's dry run, which plans the detach before the wipe.
    --assume-detached) assume_detached=true; shift ;;
    # A site holds only the maas-db read replica; the primary lives on the hub.
    --wipe-maas-db-primary) wipe_primary=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
if [ -z "$kubeconfig" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  . "$here/clusters.sh"
  clusters_load "$here/.." || exit 1
  site=$(site_name "$name") || exit 1
  cluster_login_ok "$site" || exit 1
  kubeconfig=$(cluster_kubeconfig "$site")
fi
$assume_detached && ! $dry_run && die "--assume-detached is only for --dry-run"
k() { oc --kubeconfig "$kubeconfig" "$@"; }

contains() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
for ns in $NAMESPACES; do contains "$PROTECTED_NAMESPACES" "$ns" && die "namespace $ns is protected"; done
for p in $OPERATOR_PACKAGES; do contains "$PROTECTED_PACKAGES" "$p" && die "package $p is protected"; done

k get managedcluster >/dev/null 2>&1 && die "this cluster is an ACM hub; wipe-site.sh is for sites"
$assume_detached || { k get ns open-cluster-management-agent >/dev/null 2>&1 &&
  die "the cluster is still managed by a hub: detach it first, on the old hub or, when that hub is gone, with make site-detach (page 5)"; }

# A CloudNativePG Cluster in maas-db that isn't a replica is a MaaS database
# primary, which belongs on the hub: refuse to delete it unless asked to.
DB_CLUSTER=clusters.postgresql.cnpg.io
if ! $wipe_primary && k api-resources --api-group=postgresql.cnpg.io -o name 2>/dev/null | grep -qx "$DB_CLUSTER"; then
  dbs=$(k get "$DB_CLUSTER" -n maas-db -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replica.enabled}{"\n"}{end}' 2>&1) ||
    die "can't list the databases in namespace maas-db, so can't tell a read replica from a primary: $(tail -n1 <<<"$dbs")"
  primaries=$(awk -F'|' '$1 != "" && $2 != "true" {print $1}' <<<"$dbs" | tr '\n' ' ')
  [ -z "$primaries" ] || die "namespace maas-db holds a database that isn't a read replica ($DB_CLUSTER: ${primaries% }); it looks like the MaaS database primary, which a site doesn't run. To delete it anyway, run scripts/wipe-site.sh with --wipe-maas-db-primary"
fi

del() { # del ARGS... : delete, or print what would be deleted
  if $dry_run; then echo "would delete: $*"; else k delete "$@" --ignore-not-found --wait=false; fi
}
wait_gone() { # wait_gone DESCRIPTION SECONDS COMMAND...
  local what="$1" secs="$2"; shift 2
  $dry_run && return 0
  for _ in $(seq 1 $((secs / 10))); do [ -z "$("$@" 2>/dev/null)" ] && return 0; sleep 10; done
  echo "warning: $what still present after ${secs}s:" >&2; "$@" >&2 || true
}
resources_in() { k api-resources --api-group="$1" --verbs=delete -o name 2>/dev/null || true; }
list_kind() { k get "$1" -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name 2>/dev/null || true; }
del_all_stripped() { # delete every object of a kind without its finalizers (their controller is gone), skipping protected namespaces
  list_kind "$1" | while read -r ns name; do
    [ -n "$name" ] || continue
    if [ "$ns" = "<none>" ]; then set -- "$1" "$name"; else contains "$PROTECTED_NAMESPACES" "$ns" && continue; set -- "$1" "$name" -n "$ns"; fi
    if $dry_run; then echo "would delete without finalizers: $*"
    else k patch "$@" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null || true; del "$@"; fi
  done
}
del_all_of() { # delete every object of a kind, skipping protected namespaces
  list_kind "$1" | while read -r ns name; do
    [ -n "$name" ] || continue
    if [ "$ns" = "<none>" ]; then del "$1" "$name"
    elif ! contains "$PROTECTED_NAMESPACES" "$ns"; then del "$1" "$name" -n "$ns"; fi
  done
}

echo "== 0. Argo CD tracking on the platform's GPU and certificate objects"
TRACK_LABEL=app.kubernetes.io/instance TRACK_ANNOTATION=argocd.argoproj.io/tracking-id
# Applications of this cluster's own Argo CD: what they track is the platform's, and stays.
SITE_APPS=" $(k get applications.argoproj.io -A -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace}_{.metadata.name} {end}' 2>/dev/null || true) "
for kind in clusterpolicies.nvidia.com nodefeaturediscoveries.nfd.openshift.io clusterissuers.cert-manager.io; do
  { k get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/instance}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"|"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}{end}' 2>/dev/null || true; } |
    while IFS='|' read -r ns name label ann manager; do
      [ -n "$name" ] || continue
      app=${ann%%:*}   # a tracking-id is APP:GROUP/KIND:NAMESPACE/NAME
      set -- "$kind" "$name"; [ -z "$ns" ] || set -- "$@" -n "$ns"
      if { [ -n "$app" ] && contains "$SITE_APPS" "$app"; } || { [ -n "$label" ] && contains "$SITE_APPS" "$label"; }; then
        echo "kept (tracked by this cluster's own Argo CD Application ${app:-$label}): $*"; continue
      fi
      # Helm sets the same label for its release; keep it unless the tracking-id names it as the Application.
      [ "$manager" != Helm ] || [ "$label" = "$app" ] || label=""
      if [ -n "$label" ]; then
        if $dry_run; then echo "would remove label $TRACK_LABEL=$label from: $*"; else k label "$@" "$TRACK_LABEL-" >/dev/null; echo "removed label $TRACK_LABEL from: $*"; fi
      fi
      if [ -n "$ann" ]; then
        if $dry_run; then echo "would remove annotation $TRACK_ANNOTATION from: $*"; else k annotate "$@" "$TRACK_ANNOTATION-" >/dev/null; echo "removed annotation $TRACK_ANNOTATION from: $*"; fi
      fi
    done
done

echo "== 1. models"
del_all_of llminferenceservices.serving.kserve.io
wait_gone "LLMInferenceServices" 600 k get llminferenceservices.serving.kserve.io -A --no-headers
list_kind llminferenceserviceconfigs.serving.kserve.io | while read -r ns name; do
  case "$ns" in redhat-ods-applications) ;; *) [ -n "$name" ] && del llminferenceserviceconfigs.serving.kserve.io "$name" -n "$ns" ;; esac
done

echo "== 2. MaaS objects"
for g in $MAAS_GROUPS; do for r in $(resources_in "$g"); do del_all_of "$r"; done; done
# Wait for the finalizers to run, not for the kinds to empty: while the DataScienceCluster
# exists, the operator recreates its MaaS Config, MaaSTenantConfig and AITenant (site-b, 2026-11-10).
for g in $MAAS_GROUPS; do for r in $(resources_in "$g"); do
  wait_gone "$r being deleted" 600 k get "$r" -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}'
done; done

echo "== 3. DataScienceCluster, then its components"
del_all_of datascienceclusters.datasciencecluster.opendatahub.io
wait_gone "DataScienceCluster" 900 k get datascienceclusters.datasciencecluster.opendatahub.io -A --no-headers
for r in $(resources_in components.platform.opendatahub.io); do wait_gone "$r" 600 k get "$r" -A --no-headers; done
del_all_of dscinitializations.dscinitialization.opendatahub.io
wait_gone "DSCInitialization" 600 k get dscinitializations.dscinitialization.opendatahub.io -A --no-headers

# What the operator recreated after step 2 now has no controller to run its finalizers
# (maas-controller and ai-gateway-controller went with the DataScienceCluster), and would
# hold its namespace in Terminating. Delete it and drop its finalizers.
echo "== 3b. MaaS objects recreated before the DataScienceCluster went"
for g in $MAAS_GROUPS; do for r in $(resources_in "$g"); do del_all_stripped "$r"; done; done

echo "== 4. grid records"
for g in $GRID_GROUPS; do for r in $(resources_in "$g"); do del_all_of "$r"; done; done

echo "== 5. gateways and their EnvoyFilters"
for gw in $GATEWAYS; do del gateway.gateway.networking.k8s.io "$gw" -n openshift-ingress; done
for ef in $(k get envoyfilters.networking.istio.io -n openshift-ingress -o name 2>/dev/null); do del "$ef" -n openshift-ingress; done

# Submariner, which the old hub's add-on installed: its Submariner and
# ServiceDiscovery go while its operator runs, which then uninstalls the gateway,
# route agent and Globalnet from the nodes. Left behind, the old Globalnet kept
# its global IPs (242.3.0.x) after a new broker gave the cluster 242.1.0.0/16, and
# the tunnel failed one way (site-c, 2026-11-18). Then every other object of
# group submariner.io (endpoints, gateways, Globalnet's egress and ingress IPs),
# whose controllers are gone by then.
echo "== 5b. Submariner"
SUB_CRS="submariners.submariner.io servicediscoveries.submariner.io"
sub_operator=false; k get deployment submariner-operator -n submariner-operator >/dev/null 2>&1 && sub_operator=true
if $sub_operator; then
  for r in $SUB_CRS; do del_all_of "$r"; done
  for r in $SUB_CRS; do wait_gone "$r" 300 k get "$r" -A --no-headers; done
fi
for r in $(resources_in submariner.io); do
  # Already listed above; a real run strips any the operator didn't finish.
  $sub_operator && $dry_run && contains "$SUB_CRS" "$r" && continue
  del_all_stripped "$r"
done

# The maas-db read replica, while CloudNativePG runs: an old one keeps the old
# primary's systemID and roles, and maas-api then fails to sign in to maas-read-r
# (site-c, 2026-11-18). Then its volumes; the namespace goes in step 9.
echo "== 5c. maas-db read replica"
for c in $(k get "$DB_CLUSTER" -n maas-db -o name 2>/dev/null || true); do del "$c" -n maas-db; done
wait_gone "the maas-db database" 300 k get "$DB_CLUSTER" -n maas-db -o name
for v in $(k get persistentvolumeclaims -n maas-db -o name 2>/dev/null || true); do del "$v" -n maas-db; done

echo "== 6. operator-owned CRs, then operators"
# Delete what an operator reconciles while the operator still runs, or its
# finalizer never clears (seen with Kuadrant and Authorino).
for r in kuadrants.kuadrant.io authorinos.operator.authorino.kuadrant.io limitadors.limitador.kuadrant.io; do del_all_of "$r"; done
for r in kuadrants.kuadrant.io authorinos.operator.authorino.kuadrant.io limitadors.limitador.kuadrant.io; do wait_gone "$r" 300 k get "$r" -A --no-headers; done
k get subscriptions.operators.coreos.com -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name,P:.spec.name,CSV:.status.installedCSV |
  while read -r ns name pkg csv; do
    contains "$OPERATOR_PACKAGES" "$pkg" || continue
    contains "$PROTECTED_NAMESPACES" "$ns" && continue
    del subscriptions.operators.coreos.com "$name" -n "$ns"
    [ "$csv" != "<none>" ] && [ -n "$csv" ] && del clusterserviceversions.operators.coreos.com "$csv" -n "$ns"
  done

echo "== 7. leftover webhooks"
for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
  { k get "$kind" -o name | grep -E "$WEBHOOK_PATTERN" || true; } | while read -r w; do del "$w"; done
done

# What "clusteradm unjoin --purge-operator" removes, less the CRD (CRDs stay), plus
# the operator's leader lease and namespace. Its Klusterlet goes first, while the
# operator still runs to clear its finalizer.
echo "== 8. the old hub's klusterlet operator and AppliedManifestWorks"
KLUSTERLET=klusterlets.operator.open-cluster-management.io
if k get "$KLUSTERLET" klusterlet -o name >/dev/null 2>&1; then
  del "$KLUSTERLET" klusterlet
  wait_gone "Klusterlet" 300 k get "$KLUSTERLET" klusterlet -o name
fi
# The old hub's AppliedManifestWorks: after an import they'd co-own objects with the
# new hub's works, so removing an add-on there would uninstall nothing (site-c,
# 2026-11-18). The work agent that owns their finalizer is gone.
for a in $(k get appliedmanifestworks.work.open-cluster-management.io -o name 2>/dev/null || true); do
  if $dry_run; then echo "would delete without finalizers: $a"
  else k patch "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; del "$a"; fi
done
if k get ns open-cluster-management >/dev/null 2>&1; then
  del deployment.apps klusterlet -n open-cluster-management
  del lease.coordination.k8s.io klusterlet-lock -n open-cluster-management
  del serviceaccount klusterlet -n open-cluster-management
  del clusterrolebinding.rbac.authorization.k8s.io klusterlet
  del clusterrole.rbac.authorization.k8s.io klusterlet
  # Its operator is gone, so nothing else clears a Klusterlet that didn't go.
  if k get "$KLUSTERLET" klusterlet -o name >/dev/null 2>&1; then
    if $dry_run; then echo "would remove the finalizers from $KLUSTERLET klusterlet if it's still there"
    else k patch "$KLUSTERLET" klusterlet --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; fi
  fi
  # The namespace too, unless something else runs there.
  deploys=$(k get deployments.apps -n open-cluster-management -o name 2>&1) ||
    die "can't list the Deployments in namespace open-cluster-management: $(tail -n1 <<<"$deploys")"
  other=$(grep -vx 'deployment.apps/klusterlet' <<<"$deploys" | awk 'NF' || true)
  if [ -z "$other" ]; then
    del ns open-cluster-management
    wait_gone "namespace open-cluster-management" 600 k get ns open-cluster-management --no-headers
  else echo "kept namespace open-cluster-management: it also runs $(echo $other)"; fi
fi

echo "== 9. namespaces"
for ns in $NAMESPACES; do k get ns "$ns" >/dev/null 2>&1 && del ns "$ns"; done
for ns in $NAMESPACES; do wait_gone "namespace $ns" 600 k get ns "$ns" --no-headers; done

# Only now: Submariner's uninstall DaemonSets find the gateway nodes by this
# label. The hub labels gateway nodes again at the next import (a compact cluster
# or single-node OpenShift: label them again by hand, page 1).
echo "== 10. Submariner gateway node labels"
if ! $dry_run && k get ns submariner-operator >/dev/null 2>&1; then
  echo "warning: namespace submariner-operator is still there; kept the submariner.io/gateway node labels" >&2
else
  for n in $(k get nodes -l submariner.io/gateway -o name 2>/dev/null || true); do
    if $dry_run; then echo "would remove label submariner.io/gateway from: $n"
    else k label "$n" submariner.io/gateway- >/dev/null; echo "removed label submariner.io/gateway from: $n"; fi
  done
fi

echo "== done$($dry_run && echo ' (dry run: nothing deleted)')"
