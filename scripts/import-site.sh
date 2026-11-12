#!/usr/bin/env bash
# Import a site from clusters.yaml into the hub's ACM, with the library's
# import script at your pin (docs/acm/cluster-onboarding/import-managed-cluster.sh).
# It prints a summary and changes nothing until you add --yes.
#
#   scripts/import-site.sh NAME [--yes] [other flags of the library script]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
[ $# -ge 1 ] || { echo "usage: import-site.sh NAME [--yes]" >&2; exit 2; }
clusters_load "$here/.."
name=$1; shift
[ "$(cluster_field "$name" role)" != hub ] || { echo "error: $name is the hub" >&2; exit 1; }
hub=$(hub_name)
cluster_login_ok "$hub"; cluster_login_ok "$name"
library_dir "$here/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
merge_kubeconfigs "$hub" "$name" "$tmp/kubeconfig"
KUBECONFIG="$tmp/kubeconfig" bash "$LIB/docs/acm/cluster-onboarding/import-managed-cluster.sh" \
  --hub-context hub --spoke-context site --cluster-name "$name" "$@"
