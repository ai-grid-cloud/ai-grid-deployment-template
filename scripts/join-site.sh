#!/usr/bin/env bash
# Make a site part of the grid: label its ManagedCluster on the hub with the
# role and location from clusters.yaml. The hub then installs the site.
#
#   scripts/join-site.sh NAME
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -eq 1 ] || { echo "usage: join-site.sh NAME" >&2; exit 2; }
clusters_load "$here/.."
name=$1
role=$(cluster_field "$name" role)
[ "$role" != hub ] || { echo "error: $name is the hub; join-site.sh is for sites" >&2; exit 1; }
location=$(cluster_field "$name" location)
hub=$(hub_name)
cluster_login_ok "$hub"
KUBECONFIG=$(cluster_kubeconfig "$hub") oc label managedcluster "$name" \
  ai-grid/enabled=true ai-grid/role="$role" location="$location" --overwrite
