#!/usr/bin/env bash
# Run a command against one cluster from clusters.yaml, with its login.
#
#   scripts/with-cluster.sh NAME COMMAND [ARG ...]
#
# Sets KUBECONFIG to .config/NAME/kubeconfig after checking the login works.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -ge 2 ] || { echo "usage: with-cluster.sh NAME COMMAND [ARG ...]" >&2; exit 2; }
clusters_load "$here/.."
cluster_login_ok "$1"
KUBECONFIG=$(cluster_kubeconfig "$1"); export KUBECONFIG
shift
exec "$@"
