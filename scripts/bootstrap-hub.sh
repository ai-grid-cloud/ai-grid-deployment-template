#!/usr/bin/env bash
# Bootstrap a hub from this deployment repository (install guide, page 3). It
# uses the library at the revision the repository names: the branch it follows,
# at its tip, or the commit it pins (scripts/library.sh).
#
# 1. Checks the deployment (check-deployment.sh), that the hub can read the
#    deployment and catalog repositories with no login (check-public-repos.sh),
#    the registry logins in the
#    auth file, and the hub's prerequisites, before it writes to the hub.
#    Then labels two of the hub's worker nodes submariner.io/gateway=true for
#    Submariner's gateways, unless two already carry it (gateway-nodes.sh); on a
#    compact cluster or single-node OpenShift it stops and names the nodes to
#    label by hand; with no site in clusters.yaml yet (a hub-only install,
#    sites added later) it only warns.
# 2. Installs OpenShift GitOps from the library's bootstrap files.
# 3. Applies the deployment's root/ (the root ApplicationSet and
#    deployment-root). From then on Argo CD follows git; this script is not run
#    again.
# 4. Seeds the quay.io/rhoai pull secret and the registry.stage.redhat.io
#    login (both required) that the prerequisites
#    Policy copies to every site. The credentials are read from a container
#    auth file and never printed.
#
# Runs against the hub in clusters.yaml, with its login (.config/NAME/kubeconfig).
#
# Usage: [QUAY_AUTH_FILE=AUTH_JSON] [ALLOW_GENERIC_LOGIN=1] scripts/bootstrap-hub.sh [--deployment DIR]
#
# The quay.io/rhoai login comes from scripts/clusters.sh's deployment_load:
# quay: in .config/clusters.yaml, the environment winning, else QUAY_AUTH_FILE,
# else ~/.config/containers/auth.json or $XDG_RUNTIME_DIR/containers/auth.json
# (page by page, as make prereqs). ALLOW_GENERIC_LOGIN=1
# lets a general quay.io login stand in for a quay.io/rhoai one. The older names
# RHOAI_QUAY_AUTH_FILE and RHOAI_QUAY_ALLOW_GENERIC_LOGIN still work.
set -Eeuo pipefail
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --deployment) dir=$2; shift 2 ;;
    *) die "usage: bootstrap-hub.sh [--deployment DIR]" ;;
  esac
done
[ -d "$dir/root" ] || die "--deployment must be a checkout with root/"
for c in oc jq git; do command -v "$c" >/dev/null || die "required command not found: $c"; done
. "$here/library.sh"
library_dir "$dir" || exit 1
lib=$LIB
. "$here/clusters.sh"
deployment_load "$dir" || exit 1
auth_file=$QUAY_AUTH_FILE
[ -n "$auth_file" ] && [ -f "$auth_file" ] || die "no quay.io/rhoai login: $(secret_missing QUAY_AUTH_FILE)"
allow_generic="${ALLOW_GENERIC_LOGIN:-${RHOAI_QUAY_ALLOW_GENERIC_LOGIN:-}}"
hub=$(hub_name)
cluster_login_ok "$hub" || exit 1
KUBECONFIG=$(cluster_kubeconfig "$hub"); export KUBECONFIG
echo "Hub: $hub ($(oc whoami --show-server))."
bash "$here/check-deployment.sh" "$dir"
# The hub's Argo CD reads the deployment and catalog repositories with no login:
# a private one stops here, before any write; a network error only warns.
# make install runs this check itself and sets PUBLIC_REPOS_CHECKED=1.
[ "${PUBLIC_REPOS_CHECKED:-}" = 1 ] || bash "$here/check-public-repos.sh" --network-warn "$dir" ||
  die "the hub can't read a repository with no login (FAIL above): make it public, then run this again"
. "$here/deployment-inputs.sh"
deployment_render "$dir"
echo "Library at $(deployment_input libraryRevision) (commit $(git -C "$lib" rev-parse --short=12 HEAD))."

# Read the logins before any write, so a refused auth file leaves the hub as it
# was. Prefer a login scoped to quay.io/rhoai (a robot token). A general quay.io
# login is copied to the hub and to every site's pull secret, so using one needs
# ALLOW_GENERIC_LOGIN=1.
jq -e '.auths | type == "object"' "$auth_file" >/dev/null 2>&1 || die "can't read $auth_file as a container auth file"
if ! RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io/rhoai"].auth' "$auth_file" 2>/dev/null)"; then
  [ "$allow_generic" = 1 ] ||
    die "no quay.io/rhoai login in $auth_file; add a robot token for quay.io/rhoai, or set ALLOW_GENERIC_LOGIN=1 to use the general quay.io login"
  RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io"].auth' "$auth_file")" || die "no quay.io login in $auth_file"
fi
export RHOAI_QUAY_PULL_SECRET
# The library mirrors registry.redhat.io/rhaii* (model runtimes) to
# registry.stage.redhat.io with mirrorSourcePolicy NeverContactSource on every
# site that isn't HCP, so without a stage login no model runtime pulls there
# (docs/upstream-main-limits.md, L20). Stop before any write.
RHOAI_STAGE_PULL_SECRET="$(jq -er '.auths["registry.stage.redhat.io"].auth' "$auth_file" 2>/dev/null)" ||
  die "no registry.stage.redhat.io login in $auth_file; sites pull model runtimes only from registry.redhat.io/rhaii* mirrored to stage, so add one (podman login registry.stage.redhat.io into that auth file, or stage: beside quay: in .config/clusters.yaml); see docs/upstream-main-limits.md, L20"
export RHOAI_STAGE_PULL_SECRET

# hubCertManager (root/inputs.env): library installs cert-manager from the root,
# which a hub already running the platform's can't take; that stops here.
cert_manager=$(deployment_input hubCertManager)
pre_rc=0
pre=$(RHOAI_QUAY_PULL_SECRET_FILE="$auth_file" bash "$here/check-prerequisites.sh" --step hub --kubeconfig "$KUBECONFIG" \
  --cert-manager "$cert_manager" 2>&1) || pre_rc=$?
[ "$pre_rc" != 2 ] || die "check-prerequisites.sh: $(tail -n1 <<<"$pre")"
[ "$pre_rc" = 0 ] || echo "Prerequisites incomplete before install; the ones this script installs are expected to be missing."
printf '%s\n' "$pre"
! grep -qE '^(FOUND|MISSING) *cert-manager OperatorGroup' <<<"$pre" ||
  die "the hub runs the platform's cert-manager, and hubCertManager is library: set hubCertManager=platform in root/inputs.env, commit it, then run this again"

# Nothing in the library labels the hub's Submariner gateway nodes on this root
# (scripts/gateway-nodes.sh), so the hub would run no gateway. A hub-only
# install with no sites yet (sites: []) has no tunnel to carry, so there it
# only warns.
if [ -n "$(site_names)" ]; then
  bash "$here/gateway-nodes.sh" --kubeconfig "$KUBECONFIG" "$hub"
else
  bash "$here/gateway-nodes.sh" --kubeconfig "$KUBECONFIG" "$hub" ||
    echo "warning: no Submariner gateway nodes on the hub; the hub needs them before its first site joins" >&2
fi

oc apply -f "$lib/bootstrap/namespace.yaml" -f "$lib/bootstrap/gitops-operator-group.yaml" -f "$lib/bootstrap/openshift-gitops-sub.yaml"
for crd in applications.argoproj.io applicationsets.argoproj.io; do
  for _ in $(seq 1 120); do oc get crd "$crd" >/dev/null 2>&1 && break; sleep 5; done
  oc wait --for=condition=Established "crd/$crd" --timeout=5m
done
for _ in $(seq 1 120); do
  [ "$(oc -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ] && break; sleep 5
done
oc apply -f "$lib/bootstrap/openshift-gitops-admin.yaml"
# Give Argo CD's application controller the memory the library's gitops-config sets
# (apps/gitops-config/manifests/argocd.yaml), before the root fans out. On a fresh hub
# gitops-config can't apply it until ACM is installed, and with the operator's default
# limit the controller runs out of memory first, so ACM never finishes. Same values,
# so gitops-config's server-side apply takes them over without a conflict.
patch=$(KUBECONFIG=/dev/null oc label --local -f "$lib/apps/gitops-config/manifests/argocd.yaml" ai-grid.dev/read=true -o json |
  jq -c '{spec: {controller: {resources: .spec.controller.resources}}}')
oc patch argocd openshift-gitops -n openshift-gitops --type merge -p "$patch"
printf "%s\n" "$DEPLOYMENT_ROOT" | oc apply -f -

bash "$lib/apps/rhoai-prerequisites/create-hub-secret.sh"
echo "Bootstrapped. Check progress with: make status"
