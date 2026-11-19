#!/usr/bin/env bash
# Reports, one line each, whether a cluster has the infrastructure an install
# step needs before AI Grid components go on it. Read only: it never changes
# the cluster and never reads a Secret's data.
#
# Usage: scripts/check-prerequisites.sh --step hub|spoke --cluster NAME|--kubeconfig FILE [--cert-manager library|platform]
#        [--expect-idp library|own]
#        [--idp-secret NS/NAME:KEY --idp-ca NS/NAME:KEY]
#
#   --cert-manager the hub's cert-manager (root/inputs.env hubCertManager):
#                  library (default; the root installs it, so the platform's
#                  must not be there), platform (its CRDs must be) or site (for
#                  a hub that is also a site, which isn't supported; still
#                  accepted, and checked as platform)
#   --step hub     the hub, before and after its infrastructure step: OpenShift
#                  version, a default StorageClass, cert-manager, the
#                  quay.io/rhoai pull-secret file ($RHOAI_QUAY_PULL_SECRET_FILE)
#                  and the object-storage Secret (the library's apps/odf writes it)
#   --step spoke   a spoke (with no --cluster, the only site in clusters.yaml) before it joins ACM: OpenShift version, a default
#                  StorageClass (the hub's policies deliver its pull secret),
#                  and a previous install (a klusterlet, a DataScienceCluster, a model,
#                  the OpenShift AI Subscription, grid objects, an install
#                  namespace stuck in Terminating)
#   --expect-idp   the tenant IdP on this cluster: own (the deployment's own,
#                  any OIDC provider) checks
#                  the tenant Policy's two IdP inputs on this cluster: the
#                  idpClientSecret* Secret (--idp-secret) and the idpCA*
#                  ConfigMap (--idp-ca), each present with its key; both flags
#                  are required with own. library (apps/keycloak, a plain
#                  Deployment) adds no check, since what it needs are
#                  components (apps/maas-db, apps/external-secrets)
#
# Prints OK, MISSING or FOUND per check and exits 1 if anything isn't OK, 2 on
# bad usage. A key is checked for presence only; its value is never printed.
set -Eeuo pipefail

usage() { sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

step="" kubeconfig="" cluster="" idp="" idp_secret="" idp_ca="" cert_manager=library
while [ $# -gt 0 ]; do
  case "$1" in
    --step) step=${2:-}; shift 2 ;;
    --kubeconfig) kubeconfig=${2:-}; shift 2 ;;
    --cluster) cluster=${2:-}; shift 2 ;;
    --expect-idp) idp=${2:-}; shift 2 ;;
    --cert-manager) cert_manager=${2:-}; shift 2 ;;
    --idp-secret) idp_secret=${2:-}; shift 2 ;;
    --idp-ca) idp_ca=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
case "$step" in hub|spoke) ;; *) echo "--step must be hub or spoke" >&2; usage ;; esac
only_site=false; [ -z "$cluster" ] && [ -z "$kubeconfig" ] && [ "$step" = spoke ] && only_site=true
. "$(dirname "$0")/clusters.sh"
if [ -n "$cluster" ] || $only_site; then
  clusters_load "$(dirname "$0")/.." || exit 2
  ! $only_site || cluster=$(site_name) || exit 2
  cluster_login_ok "$cluster" || exit 2
  kubeconfig=$(cluster_kubeconfig "$cluster")
fi
[ -f "$kubeconfig" ] || { echo "--cluster or --kubeconfig is required" >&2; usage; }
case "$idp" in ""|library|own) ;; *) echo "--expect-idp must be library or own" >&2; usage ;; esac
case "$cert_manager" in library|platform|site) ;; *) echo "--cert-manager must be library, platform or site" >&2; usage ;; esac
ref_ok() { [[ $1 =~ ^[a-z0-9.-]+/[a-z0-9.-]+:[A-Za-z0-9._-]+$ ]]; }
if [ "$idp" = own ]; then
  if ! ref_ok "$idp_secret" || ! ref_ok "$idp_ca"; then
    echo "--expect-idp own needs --idp-secret and --idp-ca as NS/NAME:KEY" >&2; usage
  fi
fi

MIN_MINOR=21
missing=0
oc_() { oc --kubeconfig "$kubeconfig" "$@"; }
report() { # OK|MISSING what detail
  printf '%-8s %-40s %s\n' "$1" "$2" "${3:-}"
  [ "$1" = OK ] || missing=1
}

# OpenShift 4.21 or later.
version=$(oc_ get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
minor=$(echo "$version" | awk -F. '$1 == 4 {print $2}')
if [ -n "$minor" ] && [ "$minor" -ge "$MIN_MINOR" ]; then
  report OK "OpenShift 4.$MIN_MINOR or later" "$version"
else
  report MISSING "OpenShift 4.$MIN_MINOR or later" "${version:-unreadable}"
fi

# A default StorageClass: databases, S4 and Loki claim PVCs without naming one.
default_sc=$(oc_ get storageclass -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null |
  awk '$2 == "true" {print $1}' | paste -sd, - || true)
if [ -n "$default_sc" ]; then report OK "default StorageClass" "$default_sc"; else report MISSING "default StorageClass" "none annotated is-default-class"; fi

crds_present() { local crd; for crd in "$@"; do oc_ get crd "$crd" -o name >/dev/null 2>&1 || return 1; done; }

if [ "$step" = hub ]; then
  # cert-manager: grid enrollment issues its CA and identities with it.
  if [ "$cert_manager" != library ]; then
    if crds_present certificates.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io; then
      report OK "cert-manager CRDs" "present (hubCertManager=$cert_manager)"
    else
      report MISSING "cert-manager CRDs" "hubCertManager=$cert_manager, but the hub has no cert-manager: install it, or set hubCertManager=library"
    fi
  else
    # The root installs the library's, whose OperatorGroup is
    # openshift-cert-manager-operator; any other one in that namespace is the
    # platform's, and two OperatorGroups fail both (TooManyOperatorGroups). The
    # platform's CLI install uses the same name (OpenShift 4.21 docs, "Install
    # the cert-manager Operator for Red Hat OpenShift by using the CLI"), so the
    # name alone isn't the library's: only Argo CD's tracking for the library's
    # Application cert-manager is, as the label app.kubernetes.io/instance or
    # the annotation argocd.argoproj.io/tracking-id (APP:GROUP/KIND:NS/NAME).
    # stderr apart: an oc Warning: line isn't an OperatorGroup.
    read_ok=1 og_err=$(mktemp)
    if ! ogs=$(oc_ get operatorgroups.operators.coreos.com -n cert-manager-operator \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/instance}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' 2>"$og_err"); then
      report MISSING "cert-manager OperatorGroup" "can't read OperatorGroups in cert-manager-operator: $(tail -n1 "$og_err")"
      other="" read_ok=""
    else
      other=$(while IFS='|' read -r og label ann; do
          [ -n "$og" ] || continue
          [ "$og" = openshift-cert-manager-operator ] && { [ "$label" = cert-manager ] || [ "${ann%%:*}" = cert-manager ]; } && continue
          echo "$og"
        done <<<"$ogs" | head -n1 || true)
    fi
    rm -f "$og_err"
    if [ -n "$other" ]; then
      report FOUND "cert-manager OperatorGroup" "$other: the hub runs the platform's cert-manager; set hubCertManager=platform in root/inputs.env"
    elif [ -n "$read_ok" ]; then
      report OK "cert-manager" "the root installs the library's (hubCertManager=library)"
    fi
  fi
  # The pull secret for quay.io/rhoai, which apps/rhoai-prerequisites
  # distributes; never read here, only found.
  if [ -n "${RHOAI_QUAY_PULL_SECRET_FILE:-}" ] && [ -s "$RHOAI_QUAY_PULL_SECRET_FILE" ]; then
    report OK "quay.io/rhoai pull secret file" "\$RHOAI_QUAY_PULL_SECRET_FILE"
  else
    report MISSING "quay.io/rhoai pull secret file" "set RHOAI_QUAY_PULL_SECRET_FILE to a non-empty file"
  fi
  # The object-storage contract. Missing before the infrastructure step.
  if oc_ get secret thanos-object-storage -n open-cluster-management-observability -o name >/dev/null 2>&1; then
    report OK "object storage" "open-cluster-management-observability/thanos-object-storage"
  else
    report MISSING "object storage" "Secret open-cluster-management-observability/thanos-object-storage (apps/odf writes it once ODF is installed)"
  fi
fi

if [ "$step" = spoke ]; then
  # A previous install: a klusterlet (another hub manages the cluster), a
  # DataScienceCluster, the OpenShift AI operator's Subscription, or grid
  # objects. Leftover CRDs alone are harmless.
  found=() ours=false ours_note=""
  if oc_ get namespace open-cluster-management-agent -o name >/dev/null 2>&1; then
    # Your own hub, when it has a ManagedCluster of this cluster's name whose
    # client URL is this cluster's api in clusters.yaml, joined or not: a
    # half-imported site is this hub's, and import-site.sh finishes it. A
    # ManagedCluster of that name with no client URL yet counts as ours too.
    if [ -n "$cluster" ] && hub=$(hub_name) && cluster_login_ok "$hub" 2>/dev/null; then
      mc=$(oc --kubeconfig "$(cluster_kubeconfig "$hub")" get managedcluster "$cluster" \
        -o jsonpath='{.metadata.name} {.spec.managedClusterClientConfigs[0].url}' 2>/dev/null || true)
      read -r mc_name mc_url _ <<<"$mc" || true
      if [ "${mc_name:-}" = "$cluster" ]; then
        if [ -z "${mc_url:-}" ]; then
          ours=true ours_note=" (ManagedCluster $cluster has no client URL yet; import-site.sh finishes it)"
        elif [ "${mc_url%/}" = "$(cluster_api "$cluster" | sed 's#/*$##')" ]; then
          ours=true
        fi
      fi
    fi
    $ours || found+=("klusterlet (namespace open-cluster-management-agent: another hub, or one this check can't match, manages this cluster)")
  elif oc_ get deployment klusterlet -n open-cluster-management -o name >/dev/null 2>&1; then
    # Detached, but the old hub's klusterlet operator still runs: a new import can
    # time out waiting for it to give up its lease (site-c, 2026-11-18).
    found+=("klusterlet operator left by an old hub (Deployment open-cluster-management/klusterlet)")
  fi
  [ -n "$(oc_ get datascienceclusters -A -o name 2>/dev/null || true)" ] && found+=("DataScienceCluster")
  oc_ get subscriptions.operators.coreos.com rhods-operator -n redhat-ods-operator -o name >/dev/null 2>&1 &&
    found+=("Subscription redhat-ods-operator/rhods-operator")
  [ -n "$(oc_ get gridnetworks,gridsites -A -o name 2>/dev/null || true)" ] && found+=("GridNetwork or GridSite")
  [ -n "$(oc_ get llminferenceservices -A -o name 2>/dev/null || true)" ] && found+=("LLMInferenceService")
  # An install namespace stuck in Terminating blocks a reinstall's writes into it.
  for ns in $(oc_ get namespaces -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
    grep -E "$INSTALL_NS_RE" || true); do found+=("namespace $ns in Terminating"); done
  if $ours; then
    report OK "previous AI Grid install" "already a site of this hub$ours_note"
  elif [ ${#found[@]} -gt 0 ]; then
    report FOUND "previous AI Grid install" \
      "$(IFS=,; echo "${found[*]}" | sed 's/,/, /g'); follow \"Reuse a cluster from another hub\" (page 5) first"
  elif oc_ get crds -o name 2>/dev/null | grep -qE 'opendatahub\.io|kserve\.io|grid\.praxis\.fast'; then
    report OK "previous AI Grid install" "leftover CRDs only; safe"
  else
    report OK "previous AI Grid install" "none"
  fi
fi

if [ "$idp" = own ]; then
  # The tenant Policy's hub templates read these by namespace, name and key.
  # The go-template prints "present" or nothing, never the value.
  has_key() { # kind NS/NAME:KEY
    local ns=${2%%/*} rest=${2#*/}; local name=${rest%%:*} key=${rest#*:}
    [ "$(oc_ get "$1" "$name" -n "$ns" -o go-template="{{if index .data \"$key\"}}present{{end}}" 2>/dev/null || true)" = present ]
  }
  if has_key secret "$idp_secret"; then report OK "IdP client secret" "$idp_secret"
  else report MISSING "IdP client secret" "$idp_secret (Secret with that key; the idpClientSecret* inputs)"; fi
  if has_key configmap "$idp_ca"; then report OK "IdP CA" "$idp_ca"
  else report MISSING "IdP CA" "$idp_ca (ConfigMap with that key; the idpCA* inputs)"; fi
fi

exit "$missing"
