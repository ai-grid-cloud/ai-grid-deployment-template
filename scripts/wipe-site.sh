#!/usr/bin/env bash
# Remove an AI Grid site's install (OpenShift AI, MaaS, the grid and their
# operators) so the cluster can join a new hub from scratch.
#
# Run it only after the site has left its old hub (labels removed, ManagedCluster
# deleted), and only after add-htpasswd-admin.sh has given the cluster a sign-in
# that doesn't depend on the platform's Keycloak.
#
# Order follows the 2026-11-03 fresh-install findings: models while KServe still
# runs (F9); MaaS tenant objects before anything they need (F3); the DSC, then
# its components, before the operator (F17); the grid's cluster-scoped records
# (F24); AI Grid gateways and their EnvoyFilters (F28); operators; leftover
# webhooks (F6); namespaces last.
#
# Never touched, whatever the lists below say: the platform's Keycloak
# (namespace keycloak, its operator, OAuth IdP rhbk), cert-manager, NFD, the GPU
# operator, ACME ClusterIssuers, and every openshift-*/kube-* namespace not
# listed below. Cluster-wide pull secret and mirror changes stay: the new hub's
# prerequisites Policy manages them, and removing a mirror reboots every node.
set -Eeuo pipefail

PROTECTED_NAMESPACES="keycloak cert-manager cert-manager-operator openshift-cert-manager-operator openshift-nfd nvidia-gpu-operator openshift-config openshift-authentication openshift-ingress default"
PROTECTED_PACKAGES="rhbk-operator openshift-cert-manager-operator nfd gpu-operator-certified"

# Operators an AI Grid site's OpenShift AI install brings (package names).
OPERATOR_PACKAGES="rhods-operator rhcl-operator authorino-operator dns-operator limitador-operator cluster-observability-operator leader-worker-set loki-operator opentelemetry-product tempo-product"
# API groups whose objects belong to the install (deleted in every namespace).
MAAS_GROUPS="maas.opendatahub.io aigateway.opendatahub.io"
GRID_GROUPS="grid.praxis.fast"
# Gateways in openshift-ingress that OpenShift AI and MaaS create.
GATEWAYS="data-science-gateway openshift-ai-inference maas-default-gateway"
# Namespaces the install creates.
NAMESPACES="ai-grid-internal-models kuadrant-system limitador-redis models-as-a-service odh-observability-webhook-probe redhat-ai-grid redhat-ods-applications redhat-ods-monitoring redhat-ods-operator openshift-cluster-observability-operator openshift-lws-operator openshift-opentelemetry-operator openshift-tempo-operator openshift-operators-redhat"
WEBHOOK_PATTERN='kserve|opendatahub|odh-|llminferenceservice'

usage() { echo "Usage: wipe-site.sh --kubeconfig PATH [--dry-run]"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kubeconfig="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[ -n "$kubeconfig" ] || { usage >&2; die "--kubeconfig is required"; }
k() { oc --kubeconfig "$kubeconfig" "$@"; }

contains() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
for ns in $NAMESPACES; do contains "$PROTECTED_NAMESPACES" "$ns" && die "namespace $ns is protected"; done
for p in $OPERATOR_PACKAGES; do contains "$PROTECTED_PACKAGES" "$p" && die "package $p is protected"; done

# The htpasswd sign-in must exist before anything is removed (F7, F8).
k get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.type}{"\n"}{end}' | grep -qx HTPasswd ||
  die "no HTPasswd identity provider: run add-htpasswd-admin.sh first"
k get managedcluster >/dev/null 2>&1 && die "this cluster is an ACM hub; wipe-site.sh is for sites"
k get ns open-cluster-management-agent >/dev/null 2>&1 && die "the cluster is still managed by a hub: detach it first"

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
del_all_of() { # delete every object of a kind, skipping protected namespaces
  list_kind "$1" | while read -r ns name; do
    [ -n "$name" ] || continue
    if [ "$ns" = "<none>" ]; then del "$1" "$name"
    elif ! contains "$PROTECTED_NAMESPACES" "$ns"; then del "$1" "$name" -n "$ns"; fi
  done
}

echo "== 1. models (F9)"
del_all_of llminferenceservices.serving.kserve.io
wait_gone "LLMInferenceServices" 600 k get llminferenceservices.serving.kserve.io -A --no-headers
list_kind llminferenceserviceconfigs.serving.kserve.io | while read -r ns name; do
  case "$ns" in redhat-ods-applications) ;; *) [ -n "$name" ] && del llminferenceserviceconfigs.serving.kserve.io "$name" -n "$ns" ;; esac
done

echo "== 2. MaaS objects (F3)"
for g in $MAAS_GROUPS; do for r in $(resources_in "$g"); do del_all_of "$r"; done; done
for g in $MAAS_GROUPS; do for r in $(resources_in "$g"); do wait_gone "$r" 600 k get "$r" -A --no-headers; done; done

echo "== 3. DataScienceCluster, then its components (F17)"
del_all_of datascienceclusters.datasciencecluster.opendatahub.io
wait_gone "DataScienceCluster" 900 k get datascienceclusters.datasciencecluster.opendatahub.io -A --no-headers
for r in $(resources_in components.platform.opendatahub.io); do wait_gone "$r" 600 k get "$r" -A --no-headers; done
del_all_of dscinitializations.dscinitialization.opendatahub.io
wait_gone "DSCInitialization" 600 k get dscinitializations.dscinitialization.opendatahub.io -A --no-headers

echo "== 4. grid records (F24)"
for g in $GRID_GROUPS; do for r in $(resources_in "$g"); do del_all_of "$r"; done; done

echo "== 5. gateways and their EnvoyFilters (F28)"
for gw in $GATEWAYS; do del gateway.gateway.networking.k8s.io "$gw" -n openshift-ingress; done
for ef in $(k get envoyfilters.networking.istio.io -n openshift-ingress -o name 2>/dev/null); do del "$ef" -n openshift-ingress; done

echo "== 6. operator-owned CRs, then operators"
# Delete what an operator reconciles while the operator still runs, or its
# finalizer never clears (seen on site-b: Kuadrant and Authorino).
for r in kuadrants.kuadrant.io authorinos.operator.authorino.kuadrant.io limitadors.limitador.kuadrant.io; do del_all_of "$r"; done
for r in kuadrants.kuadrant.io authorinos.operator.authorino.kuadrant.io limitadors.limitador.kuadrant.io; do wait_gone "$r" 300 k get "$r" -A --no-headers; done
k get subscriptions.operators.coreos.com -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name,P:.spec.name,CSV:.status.installedCSV |
  while read -r ns name pkg csv; do
    contains "$OPERATOR_PACKAGES" "$pkg" || continue
    contains "$PROTECTED_NAMESPACES" "$ns" && continue
    del subscriptions.operators.coreos.com "$name" -n "$ns"
    [ "$csv" != "<none>" ] && [ -n "$csv" ] && del clusterserviceversions.operators.coreos.com "$csv" -n "$ns"
  done

echo "== 7. leftover webhooks (F6)"
for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
  { k get "$kind" -o name | grep -E "$WEBHOOK_PATTERN" || true; } | while read -r w; do del "$w"; done
done

echo "== 8. namespaces"
for ns in $NAMESPACES; do k get ns "$ns" >/dev/null 2>&1 && del ns "$ns"; done
for ns in $NAMESPACES; do wait_gone "namespace $ns" 600 k get ns "$ns" --no-headers; done

echo "== done$($dry_run && echo ' (dry run: nothing deleted)')"
