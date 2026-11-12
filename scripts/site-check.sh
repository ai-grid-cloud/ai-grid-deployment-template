#!/usr/bin/env bash
# Check a site before it joins ACM (install guide, page 5; make site-check).
# Read only. Runs check-prerequisites.sh --step spoke (OpenShift version, a
# default StorageClass, a previous AI Grid install), then checks that the
# site's apps domain resolves (router-default.APPS_DOMAIN).
#
#   scripts/site-check.sh [NAME]     NAME defaults to the only site in clusters.yaml
#
# Prints OK, MISSING or FOUND per check, and exits 1 if anything isn't OK.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
name=$(site_name "${1:-}")
cluster_login_ok "$name"
rc=0
"$here/check-prerequisites.sh" --step spoke --cluster "$name" || rc=1
domain=$(KUBECONFIG=$(cluster_kubeconfig "$name") oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
if python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], 443)' "router-default.$domain" 2>/dev/null; then
  printf '%-8s %-40s %s\n' OK "apps domain DNS" "router-default.$domain resolves"
else
  printf '%-8s %-40s %s\n' MISSING "apps domain DNS" "router-default.$domain doesn't resolve: check the cluster's DNS"
  rc=1
fi
exit "$rc"
