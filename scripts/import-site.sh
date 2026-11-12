#!/usr/bin/env bash
# Import a site from clusters.yaml into the hub's ACM, with the library's
# import script at your pin (docs/acm/cluster-onboarding/import-managed-cluster.sh).
# It prints a summary and changes nothing until you add --yes.
#
#   scripts/import-site.sh [NAME] [--yes] [other flags of the library script]
#
# NAME defaults to the only site in clusters.yaml.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then name=$(site_name "$1"); shift; else name=$(site_name); fi
[ "$(cluster_field "$name" role)" != hub ] || { echo "error: $name is the hub" >&2; exit 1; }
hub=$(hub_name)
cluster_login_ok "$hub"; cluster_login_ok "$name"
library_dir "$here/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
merge_kubeconfigs "$hub" "$name" "$tmp/kubeconfig"
KUBECONFIG="$tmp/kubeconfig" bash "$LIB/docs/acm/cluster-onboarding/import-managed-cluster.sh" \
  --hub-context hub --spoke-context site --cluster-name "$name" "$@"
