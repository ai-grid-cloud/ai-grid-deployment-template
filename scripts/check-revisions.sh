#!/usr/bin/env bash
# Check that every Argo CD Application on the hub that reads the library runs
# your pinned commit, with the library's scripts/check-revisions.sh at your pin.
# Read only; exits 1 if any Application is off the pin.
#
#   scripts/check-revisions.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
library_dir "$here/.."
exec bash "$LIB/scripts/check-revisions.sh" --deployment "$here/.." --kubeconfig "$(cluster_kubeconfig "$hub")"
