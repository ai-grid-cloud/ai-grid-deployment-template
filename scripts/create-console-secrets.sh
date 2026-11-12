#!/usr/bin/env bash
# Runs the library's apps/console/create-secrets.sh at your pin against the hub
# from the clusters file (install guide, page 4). Takes the same environment
# variables; see that script.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
library_dir "$here/.."
KUBECONFIG=$(cluster_kubeconfig "$hub") exec bash "$LIB/apps/console/create-secrets.sh" "$@"
