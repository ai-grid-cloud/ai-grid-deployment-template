#!/usr/bin/env bash
# After an uninstall (install guide, page 8; make uninstall-check), show for
# each cluster in clusters.yaml: any Argo CD Applications left (the uninstall
# keeps the CRD, so the kind may stay), any install namespaces left, any
# namespace stuck in Terminating, and the identity providers its sign-in uses.
# Read only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
for name in $(hub_name) $(site_names); do
  echo "== $name"
  cluster_login_ok "$name" || continue
  c() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }
  if ! c api-resources --api-group=argoproj.io -o name 2>/dev/null | grep -q '^applications\.'; then
    echo "Argo CD Applications: none"   # the kind isn't served
  elif apps=$(c get applications.argoproj.io -A -o name 2>/dev/null); then
    n=$(grep -c . <<<"$apps" || true)
    if [ "$n" = 0 ]; then echo "Argo CD Applications: none"; else echo "Argo CD Applications: $n left"; fi
  else
    echo "Argo CD Applications: couldn't list them"
  fi
  left=$(c get ns -o name 2>/dev/null | sed 's#^namespace/##' |
    grep -E "$INSTALL_NS_RE" | tr '\n' ' ' || true)
  echo "Install namespaces left: ${left:-none}"
  term=$(c get ns -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
    grep . | tr '\n' ' ' | sed 's/ $//' || true)
  echo "Namespaces in Terminating: ${term:-none}"
  echo "Sign-in identity providers: $(c get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)"
done
