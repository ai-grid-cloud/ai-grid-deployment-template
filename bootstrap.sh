#!/usr/bin/env bash
# Bootstrap this deployment's hub (install step 1's GitOps part, then step 2).
#
# 1. Checks the hub's prerequisites with the library's check at the pinned commit.
# 2. Installs OpenShift GitOps from the library's bootstrap files at that commit.
# 3. Applies root/ (the root ApplicationSet and deployment-root). From then on
#    Argo CD follows git; this script is not run again.
# 4. Seeds the quay.io/rhoai pull secret that the library's prerequisites
#    Policy copies to every site. The credential is read from a container auth
#    file and never printed.
#
# Usage: KUBECONFIG=HUB_KUBECONFIG RHOAI_QUAY_AUTH_FILE=AUTH_JSON ./bootstrap.sh
set -Eeuo pipefail
cd "$(dirname "$0")"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
for c in oc kustomize jq git; do command -v "$c" >/dev/null || die "required command not found: $c"; done
auth_file="${RHOAI_QUAY_AUTH_FILE:-}"
[ -f "$auth_file" ] || die "set RHOAI_QUAY_AUTH_FILE to a container auth file (such as ~/.config/containers/auth.json) with a quay.io/rhoai login"

sha="$(sed -n 's#.*bootstrap/hub?ref=\([0-9a-f]\{40\}\).*#\1#p' root/kustomization.yaml)"
repo="$(sed -n 's#.*- \(https://github.com/[^/]*/[^/]*\)//bootstrap/hub?ref=.*#\1#p' root/kustomization.yaml)"
[ -n "$sha" ] && [ -n "$repo" ] || die "could not read the library's repository and commit from root/kustomization.yaml"
lib="$(mktemp -d)"; trap 'rm -rf "$lib"' EXIT
git clone -q --filter=blob:none "$repo.git" "$lib" && git -C "$lib" checkout -q "$sha"
echo "Library $repo at $sha."

RHOAI_QUAY_PULL_SECRET_FILE="$auth_file" bash "$lib/scripts/check-prerequisites.sh" --step hub --context "$(oc config current-context)" ||
  echo "Prerequisites incomplete before install; the ones this script installs are expected to be missing."

oc apply -f "$lib/bootstrap/namespace.yaml" -f "$lib/bootstrap/gitops-operator-group.yaml" -f "$lib/bootstrap/openshift-gitops-sub.yaml"
for crd in applications.argoproj.io applicationsets.argoproj.io; do
  for _ in $(seq 1 120); do oc get crd "$crd" >/dev/null 2>&1 && break; sleep 5; done
  oc wait --for=condition=Established "crd/$crd" --timeout=5m
done
for _ in $(seq 1 120); do
  [ "$(oc -n openshift-gitops get argocd openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ] && break; sleep 5
done
oc apply -f "$lib/bootstrap/openshift-gitops-admin.yaml"
kustomize build root/ | oc apply -f -

# Prefer a login scoped to quay.io/rhoai (a robot token). A general quay.io
# login is copied to the hub and to every site's pull secret, so using one needs
# RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1.
if ! RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io/rhoai"].auth' "$auth_file" 2>/dev/null)"; then
  [ "${RHOAI_QUAY_ALLOW_GENERIC_LOGIN:-}" = 1 ] ||
    die "no quay.io/rhoai login in $auth_file; add a robot token for quay.io/rhoai, or set RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1 to use the general quay.io login"
  RHOAI_QUAY_PULL_SECRET="$(jq -er '.auths["quay.io"].auth' "$auth_file")" || die "no quay.io login in $auth_file"
fi
export RHOAI_QUAY_PULL_SECRET
bash "$lib/apps/rhoai-prerequisites/create-hub-secret.sh"
echo "Bootstrapped. Watch: oc get applications.argoproj.io -n openshift-gitops"
