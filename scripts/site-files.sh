#!/usr/bin/env bash
# Write a site's own files into this deployment repository, from site-template/
# (make install runs it for each site before it imports the site; page 9):
#
#   values/clusters/NAME/rhoai.yaml  the site's OpenShift AI values
#   sites/NAME/maas-tls/             a Certificate for the MaaS hostname
#   apps/NAME-maas-tls.yaml          the Application that delivers it
#
# It reads the site, never writes to it:
#   - With sites[NAME].maasCertificate.issuer in clusters.yaml, the MaaS gateway
#     gets a certificate from that ClusterIssuer, which must exist on the site
#     and solve DNS-01, and its listeners get the hostname maas.APPS_DOMAIN.
#   - When the site already runs the platform's cert-manager operator (an
#     OperatorGroup in cert-manager-operator other than the chart's
#     openshift-cert-manager-operator), the chart's cert-manager is turned off;
#     its second OperatorGroup would fail the operator (TooManyOperatorGroups).
# With neither, it writes nothing, and removes the files it wrote earlier.
#
# Every file it writes starts with a "Written by scripts/site-files.sh" line,
# and it rewrites only those. A file of the same name without that line is
# yours: it's left as it is, and the output says what it would have written.
#
# A site already in the grid (ai-grid/enabled on its ManagedCluster) whose
# chart cert-manager would be turned off now is refused: Argo CD adopted the
# platform's namespace and Subscription and would prune them, which removes the
# operator. The message says how to protect them first (page 6).
#
#   scripts/site-files.sh [NAME]     NAME defaults to the only site in clusters.yaml
#
# Prints one line per file: wrote, removed, unchanged or kept (yours).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
clusters_load "$dir"
name=$(site_name "${1:-}")
cluster_login_ok "$name"
issuer=$(site_maas_issuer "$name")
marker="# Written by scripts/site-files.sh (make install). Delete this line to keep your own edits."
chart_og=openshift-cert-manager-operator

site_oc() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }
domain=$(site_oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}') && [ -n "$domain" ] ||
  { echo "error: can't read site $name's apps domain" >&2; exit 1; }
# It goes into sed replacements and YAML: a DNS name only.
[[ "$domain" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] ||
  { echo "error: site $name's apps domain isn't a DNS name" >&2; exit 1; }
ogs=$(site_oc get operatorgroups.operators.coreos.com -n cert-manager-operator -o jsonpath='{.items[*].metadata.name}') ||
  { echo "error: can't read site $name's OperatorGroups in cert-manager-operator" >&2; exit 1; }
platform=""
for og in $ogs; do [ "$og" = "$chart_og" ] || platform=$og; done
if [ -n "$issuer" ]; then
  site_oc get clusterissuers.cert-manager.io "$issuer" -o name >/dev/null 2>&1 ||
    { echo "error: sites[$name].maasCertificate.issuer: site $name has no ClusterIssuer $issuer" >&2; exit 1; }
fi

render() { # TEMPLATE_PATH: site-template/TEMPLATE_PATH with this site's values, on stdout
  sed -e "s/SITE/$name/g" -e "s/APPS_DOMAIN/$domain/g" -e "s/DNS01_ISSUER/$issuer/g" "$dir/site-template/$1"
}

values() { # the values file's body: the template's part after its first blank line (the gateway) with an issuer
  local body=""
  [ -z "$issuer" ] || body=$(render values/clusters/SITE/rhoai.yaml | awk 'started {print} /^$/ {started=1}')
  if [ -n "$platform" ]; then
    printf '# The platform runs cert-manager here (OperatorGroup %s), so the chart'"'"'s copy is off.\ndependencies:\n  certManager:\n    enabled: false\n' "$platform"
  fi
  [ -z "$(tr -d '[:space:]' <<<"$body")" ] || printf '%s\n' "$body"
}

ours() { [ ! -e "$dir/$1" ] || [ "$(head -n 1 "$dir/$1")" = "$marker" ]; }

put() { # PATH CONTENT: writes PATH, or removes it when CONTENT is empty
  local p=$1 content=$2
  if ! ours "$p"; then
    if [ -n "$content" ]; then echo "kept     $p (yours: no '# Written by scripts/site-files.sh' line); make install would have written:"; sed 's/^/           /' <<<"$content"
    else echo "kept     $p (yours)"; fi
    return
  fi
  if [ -z "$content" ]; then
    [ ! -e "$dir/$p" ] || { rm "$dir/$p"; rmdir -p "$(dirname "$dir/$p")" 2>/dev/null || true; echo "removed  $p"; }
    return
  fi
  content="$marker"$'\n'"$content"
  if [ -e "$dir/$p" ] && [ "$(cat "$dir/$p")" = "$content" ]; then echo "unchanged $p"; return; fi
  mkdir -p "$(dirname "$dir/$p")"
  printf '%s\n' "$content" > "$dir/$p"
  echo "wrote    $p"
}

vpath="values/clusters/$name/rhoai.yaml"
new_values=$(values)

# The cert-manager change on a site that already joined: see the header.
cm_off() { grep -q '^    enabled: false' <<<"$1"; }
if [ -n "$platform" ] && ours "$vpath" && ! cm_off "$(cat "$dir/$vpath" 2>/dev/null)"; then
  # Not imported yet (NotFound) is not in the grid; any other error stops.
  err=$(mktemp); trap 'rm -f "$err"' EXIT
  if ! joined=$(KUBECONFIG=$(cluster_kubeconfig hub) oc get managedclusters.cluster.open-cluster-management.io "$name" \
      -o jsonpath='{.metadata.labels.ai-grid/enabled}' 2>"$err"); then
    grep -q NotFound "$err" || { echo "error: can't read ManagedCluster $name on the hub: $(grep . "$err" | tail -n 1)" >&2; exit 1; }
    joined=""
  fi
  protected=$(site_oc get namespace/cert-manager-operator subscriptions.operators.coreos.com/openshift-cert-manager-operator \
    -n cert-manager-operator -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}{end}' 2>/dev/null |
    grep -c 'Prune=false' || true)
  if [ "$joined" = true ] && [ "$protected" != 2 ]; then
    cat >&2 <<EOF
error: site $name is in the grid and runs the platform's cert-manager (OperatorGroup $platform), and the chart's
cert-manager would now be turned off. Argo CD would then prune the platform's namespace cert-manager-operator and its
Subscription, which it adopted, and remove the operator. Protect both first, then run this again:

  KUBECONFIG=.config/$name/kubeconfig oc annotate namespace cert-manager-operator argocd.argoproj.io/sync-options=Prune=false
  KUBECONFIG=.config/$name/kubeconfig oc annotate subscriptions.operators.coreos.com openshift-cert-manager-operator \\
    -n cert-manager-operator argocd.argoproj.io/sync-options=Prune=false

(install guide, page 6, "A site that already runs cert-manager")
EOF
    exit 1
  fi
fi

put "$vpath" "$new_values"
for f in sites/SITE/maas-tls/certificate.yaml sites/SITE/maas-tls/kustomization.yaml apps/SITE-maas-tls.yaml; do
  put "${f//SITE/$name}" "$([ -z "$issuer" ] || render "$f")"
done
