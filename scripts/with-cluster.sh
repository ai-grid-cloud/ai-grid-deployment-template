#!/usr/bin/env bash
# Run a command against one cluster from clusters.yaml, with its login.
#
#   scripts/with-cluster.sh NAME COMMAND [ARG ...]
#
# NAME is a cluster in clusters.yaml: the hub's name or a site's.
# Sets KUBECONFIG to .config/NAME/kubeconfig after checking the login works.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -ge 2 ] || { echo "usage: with-cluster.sh NAME COMMAND [ARG ...]" >&2; exit 2; }
clusters_load "$here/.."
name=$1
cluster_login_ok "$name"
KUBECONFIG=$(cluster_kubeconfig "$name"); export KUBECONFIG
shift
exec "$@"
