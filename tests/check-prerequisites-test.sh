#!/usr/bin/env bash
# Exercises scripts/check-prerequisites.sh against a stub oc (no cluster).
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/check-prerequisites.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"; : > "$T/stub.kubeconfig"

# The stub answers from files in $STUB_DIR, in the shape the script's
# jsonpath queries print: version; storageclasses ("<name> <is-default>" per
# line); crds (one name per line); secrets ("<namespace>/<name>" per line);
# keys ("<secret|configmap> <namespace>/<name>:<key>" per line, for the
# go-template key probe, which prints only "present"). A missing file is an
# empty answer.
cat > "$T/bin/oc" <<'END_STUB'
#!/usr/bin/env bash
args=" $* "
d=$STUB_DIR
case "$args" in
  *" get clusterversion version "*) cat "$d/version" 2>/dev/null ;;
  *" get storageclass "*) cat "$d/storageclasses" 2>/dev/null ;;
  *" whoami "*) echo admin ;;
  *" get managedcluster "*) [ -f "$d/mc" ] || exit 1; cat "$d/mc" ;;
  *" get namespace "*)
    name=${args##* get namespace }; name=${name%% *}
    grep -qx "$name" "$d/namespaces" 2>/dev/null || exit 1; echo "namespace/$name" ;;
  *" get namespaces -o jsonpath="*) cat "$d/terminating" 2>/dev/null ;;
  *" get deployment klusterlet -n open-cluster-management "*) [ -f "$d/klusterlet-operator" ] || exit 1; echo deployment.apps/klusterlet ;;
  *" get datascienceclusters "*) [ -f "$d/dsc" ] || exit 1; cat "$d/dsc" ;;
  *" get subscriptions.operators.coreos.com "*) [ -f "$d/subs" ] || exit 1; cat "$d/subs" ;;
  *" get gridnetworks,gridsites "*) [ -f "$d/grid" ] || exit 1; cat "$d/grid" ;;
  *" get operatorgroups.operators.coreos.com -n cert-manager-operator "*)
    [ ! -f "$d/og-error" ] || { echo "error: Forbidden" >&2; exit 1; }
    cat "$d/ogs" 2>/dev/null || true ;;
  *" get crds -o name "*) sed 's#^#customresourcedefinition.apiextensions.k8s.io/#' "$d/crds" 2>/dev/null ;;
  *" get crd "*)
    name=${args##* get crd }; name=${name%% *}
    grep -qx "$name" "$d/crds" 2>/dev/null || exit 1; echo "$name" ;;
  *" get secret "*|*" get configmap "*)
    kind=secret; [[ $args == *" get configmap "* ]] && kind=configmap
    rest=${args##* get $kind }; name=${rest%% *}; ns=${args##* -n }; ns=${ns%% *}
    if [[ $args == *go-template* ]]; then
      key=$(sed -E 's/.*index \.data "([^"]+)".*/\1/' <<<"$args")
      grep -qx "$kind $ns/$name:$key" "$d/keys" 2>/dev/null && printf present
      exit 0
    fi
    grep -qx "$ns/$name" "$d/secrets" 2>/dev/null || exit 1; echo "$name" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
END_STUB
chmod 700 "$T/bin/oc"

fails=0; total=0
CM_CRDS=$'certificates.cert-manager.io\nissuers.cert-manager.io\nclusterissuers.cert-manager.io'
RHBK_CRDS=$'keycloaks.k8s.keycloak.org\nkeycloakrealmimports.k8s.keycloak.org'

world() { # name: a fresh stub world in $T/<name>
  local w="$T/$1"; rm -rf "$w"; mkdir -p "$w"
  echo "4.22.18" > "$w/version"
  echo "gp3-csi true" > "$w/storageclasses"
  printf '%s\n' "$CM_CRDS" > "$w/crds"
  echo "$w"
}

t() { # name want_rc expect_grep world [args...]
  local name=$1 want=$2 expect=$3 w=$4; shift 4; local rc out
  total=$((total+1))
  out=$(env -i PATH="$T/bin:/usr/bin:/bin" STUB_DIR="$w" RHOAI_QUAY_PULL_SECRET_FILE="${PULL:-}" \
    bash "$SCRIPT" --kubeconfig "$T/stub.kubeconfig" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ] && grep -qE "$expect" <<<"$out"; then
    printf '   ok   %s\n' "$name"
  else
    printf '   FAIL %s (rc=%s, wanted %s; output:)\n%s\n' "$name" "$rc" "$want" "$out"; fails=$((fails+1))
  fi
}

printf 'x' > "$T/pull"
w=$(world hub-ready); echo "open-cluster-management-observability/thanos-object-storage" > "$w/secrets"
PULL="$T/pull" t "hub with everything" 0 "^OK +object storage" "$w" --step hub
w=$(world hub-bare)
PULL="" t "hub before infrastructure" 1 "^MISSING +object storage" "$w" --step hub
PULL="" t "hub names the pull-secret file" 1 "^MISSING +quay.io/rhoai pull secret" "$w" --step hub
w=$(world old); echo "4.20.5" > "$w/version"
t "spoke on 4.20" 1 "^MISSING +OpenShift 4.21" "$w" --step spoke
w=$(world no-sc); : > "$w/storageclasses"
t "spoke without a default StorageClass" 1 "^MISSING +default StorageClass" "$w" --step spoke
w=$(world spoke-ok)
t "spoke ready" 0 "^OK +default StorageClass" "$w" --step spoke
t "spoke never used: no previous install" 0 "^OK +previous AI Grid install +none" "$w" --step spoke
w=$(world crds-only); printf '%s\n' "$CM_CRDS" datascienceclusters.datasciencecluster.opendatahub.io gridsites.grid.praxis.fast > "$w/crds"
t "leftover CRDs only: safe" 0 "^OK +previous AI Grid install +leftover CRDs only; safe" "$w" --step spoke
w=$(world old-install); echo open-cluster-management-agent > "$w/namespaces"
echo "datasciencecluster.datasciencecluster.opendatahub.io/default-dsc" > "$w/dsc"
echo "subscription.operators.coreos.com/rhods-operator" > "$w/subs"
echo "gridsite.grid.praxis.fast/site-b" > "$w/grid"
t "previous install found" 1 "^FOUND +previous AI Grid install +.*Reuse a cluster from another hub" "$w" --step spoke
t "  ... names what it found" 1 "klusterlet.*DataScienceCluster.*rhods-operator.*GridNetwork or GridSite" "$w" --step spoke
w=$(world terminating); printf 'some-app\nsubmariner-operator\n' > "$w/terminating"
t "an install namespace stuck in Terminating is a previous install" 1 "^FOUND +previous AI Grid install +namespace submariner-operator in Terminating" "$w" --step spoke
w=$(world terminating-other); echo some-app > "$w/terminating"
t "  ... another namespace in Terminating isn't" 0 "^OK +previous AI Grid install +none" "$w" --step spoke
w=$(world old-operator); touch "$w/klusterlet-operator"
t "a klusterlet operator left after a detach is a previous install" 1 "^FOUND +previous AI Grid install +klusterlet operator left by an old hub" "$w" --step spoke
w=$(world klusterlet); echo open-cluster-management-agent > "$w/namespaces"
t "a klusterlet alone is a previous install" 1 "^FOUND +previous AI Grid install +klusterlet" "$w" --step spoke
w=$(world no-cm); : > "$w/crds"
t "hubCertManager=platform, hub without cert-manager" 1 "^MISSING +cert-manager CRDs +hubCertManager=platform" "$w" --step hub --cert-manager platform
t "hubCertManager=library (default), hub without cert-manager: the root installs it" 1 "^OK +cert-manager +the root installs the library's" "$w" --step hub
w=$(world platform-cm); printf 'cert-manager-operator-og' > "$w/ogs"; echo "open-cluster-management-observability/thanos-object-storage" > "$w/secrets"
PULL="$T/pull" t "hubCertManager=library on a hub with the platform's: FOUND, says to set platform" 1 \
  "^FOUND +cert-manager OperatorGroup +cert-manager-operator-og: .*set hubCertManager=platform" "$w" --step hub
PULL="$T/pull" t "hubCertManager=platform on that hub: OK" 0 "^OK +cert-manager CRDs +present \(hubCertManager=platform\)" "$w" --step hub --cert-manager platform
# The ogs file is the jsonpath's NAME|app.kubernetes.io/instance|argocd.argoproj.io/tracking-id lines.
w=$(world library-cm); printf 'openshift-cert-manager-operator|cert-manager|\n' > "$w/ogs"; echo "open-cluster-management-observability/thanos-object-storage" > "$w/secrets"
PULL="$T/pull" t "hubCertManager=library, the library's own OperatorGroup (a rerun, label tracking): OK" 0 "^OK +cert-manager +the root installs" "$w" --step hub
w2=$(world library-cm-ann); cp "$w/secrets" "$w2/secrets"
printf 'openshift-cert-manager-operator||cert-manager:operators.coreos.com/OperatorGroup:cert-manager-operator/openshift-cert-manager-operator\n' > "$w2/ogs"
PULL="$T/pull" t "  ... annotation tracking: OK" 0 "^OK +cert-manager +the root installs" "$w2" --step hub
w2=$(world platform-cli-cm); cp "$w/secrets" "$w2/secrets"; printf 'openshift-cert-manager-operator||\n' > "$w2/ogs"
PULL="$T/pull" t "the platform's CLI install (same name, no Argo CD tracking): FOUND" 1 \
  "^FOUND +cert-manager OperatorGroup +openshift-cert-manager-operator: the hub runs the platform's" "$w2" --step hub
w2=$(world other-app-cm); cp "$w/secrets" "$w2/secrets"
printf 'openshift-cert-manager-operator|platform-operators|platform-operators:operators.coreos.com/OperatorGroup:cert-manager-operator/openshift-cert-manager-operator\n' > "$w2/ogs"
PULL="$T/pull" t "the same name tracked by another Application: FOUND" 1 "^FOUND +cert-manager OperatorGroup +openshift-cert-manager-operator" "$w2" --step hub
t "a bad --cert-manager: usage" 2 "cert-manager must be library, platform or site" "$w" --step hub --cert-manager both
PULL="$T/pull" t "hubCertManager=site (the chart owns it): its CRDs are enough" 0 "^OK +cert-manager CRDs +present \(hubCertManager=site\)" "$w" --step hub --cert-manager site
w=$(world og-error); touch "$w/og-error"; echo "open-cluster-management-observability/thanos-object-storage" > "$w/secrets"
PULL="$T/pull" t "hubCertManager=library, OperatorGroups unreadable: MISSING, not OK" 1 \
  "^MISSING +cert-manager OperatorGroup +can't read OperatorGroups in cert-manager-operator" "$w" --step hub
IDP=(--idp-secret tenant-idp/tenant-idp-client:client-secret --idp-ca openshift-config-managed/default-ingress-cert:ca-bundle.crt)
KEYS=$'secret tenant-idp/tenant-idp-client:client-secret\nconfigmap openshift-config-managed/default-ingress-cert:ca-bundle.crt'
# Any OIDC provider meets the contract: no Keycloak or RHBK CRDs required.
w=$(world own-idp); printf '%s\n' "$CM_CRDS" > "$w/crds"; printf '%s\n' "$KEYS" > "$w/keys"
t "own IdP needs no Keycloak CRDs" 0 "^OK +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP's client secret has its key" 0 "^OK +IdP client secret" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP's CA has its key" 0 "^OK +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
w=$(world own-idp-nokey); printf '%s\n%s\n' "$CM_CRDS" "$RHBK_CRDS" > "$w/crds"
echo "configmap openshift-config-managed/default-ingress-cert:ca-bundle.crt" > "$w/keys"
t "own IdP's Secret without its key" 1 "^MISSING +IdP client secret +tenant-idp/tenant-idp-client:client-secret" "$w" --step spoke --expect-idp own "${IDP[@]}"
echo "secret tenant-idp/tenant-idp-client:client-secret" > "$w/keys"
t "own IdP's CA without its key" 1 "^MISSING +IdP CA" "$w" --step spoke --expect-idp own "${IDP[@]}"
t "own IdP needs both inputs" 2 "^Usage:" "$w" --step spoke --expect-idp own
w=$(world lib-idp)
t "library Keycloak needs no RHBK" 0 "^OK +default StorageClass" "$w" --step spoke --expect-idp library
w=$(world spoke-ok2)
t "bad step" 2 "^Usage:" "$w" --step nope

# Cluster mode: a klusterlet from your own hub is your install, not a previous one.
D="$T/repo"; mkdir -p "$D/.config/hub" "$D/.config/site-b"; cp -R "$HERE/../scripts" "$D/"
: > "$D/.config/hub/kubeconfig"; : > "$D/.config/site-b/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
tc() { # name want_rc expect_grep world: --step spoke on the only site, through clusters.yaml
  local name=$1 want=$2 expect=$3 w=$4 rc out; total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$w" bash "$D/scripts/check-prerequisites.sh" --step spoke 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ] && grep -qE "$expect" <<<"$out"; then printf '   ok   %s\n' "$name"
  else printf '   FAIL %s (rc=%s, wanted %s; output:)\n%s\n' "$name" "$rc" "$want" "$out"; fails=$((fails+1)); fi
}
w=$(world installed); echo open-cluster-management-agent > "$w/namespaces"
echo "datasciencecluster.datasciencecluster.opendatahub.io/default-dsc" > "$w/dsc"
echo "gridsite.grid.praxis.fast/site-b" > "$w/grid"
# The stub prints what the script's jsonpath asks for: "<name> <client URL>".
echo "site-b https://api.site-b.example.com:6443" > "$w/mc"
tc "a site of this hub is OK" 0 "^OK +previous AI Grid install +already a site of this hub" "$w"
echo "site-b https://api.site-b.example.com:6443/" > "$w/mc"
tc "  ... with a trailing slash on the client URL" 0 "^OK +previous AI Grid install +already a site of this hub" "$w"
echo "site-b https://api.other.example.com:6443" > "$w/mc"
tc "a ManagedCluster with another API URL isn't this cluster" 1 "^FOUND +previous AI Grid install +klusterlet" "$w"
# A half-imported site (klusterlet applied, ManagedCluster not yet accepted or
# joined) is this hub's, so a re-run reaches import-site.sh and finishes it.
# Joined status isn't in the query, so this world is the same as the joined one.
echo "site-b https://api.site-b.example.com:6443" > "$w/mc"
tc "ManagedCluster exists, not joined: site-check OK" 0 "^OK +previous AI Grid install +already a site of this hub" "$w"
echo "site-b " > "$w/mc"
tc "ManagedCluster with no client config yet: ours, with a note" 0 "^OK +previous AI Grid install +already a site of this hub .*no client URL yet" "$w"
rm "$w/mc"
tc "klusterlet but no ManagedCluster on this hub: still FOUND" 1 "^FOUND +previous AI Grid install +klusterlet .*another hub" "$w"

echo "check-prerequisites tests: $((total-fails)) ok, $fails failed"; exit "$fails"
