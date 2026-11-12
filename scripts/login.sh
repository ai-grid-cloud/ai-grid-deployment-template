#!/usr/bin/env bash
# Log in to a cluster from the clusters file, into .config/NAME/kubeconfig.
#
#   scripts/login.sh NAME [oc login flags]     (make login NAME=...)
#
# With no flags it runs oc login --web, which opens your browser. To use a
# kubeconfig you already have, such as the installer's auth/kubeconfig, copy it
# to .config/NAME/kubeconfig instead.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -ge 1 ] || { echo "usage: login.sh NAME [oc login flags]" >&2; exit 2; }
clusters_load "$here/.."
name=$1; shift
api=$(cluster_field "$name" api)
k=$(cluster_kubeconfig "$name")
mkdir -p "$(dirname "$k")"; chmod 700 "$(dirname "$k")"
[ $# -gt 0 ] || set -- --web
KUBECONFIG=$k oc login --server "$api" "$@"
chmod 600 "$k"
echo "Logged in to $name as $(KUBECONFIG=$k oc whoami)."
