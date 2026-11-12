#!/usr/bin/env bash
# Log in to the clusters in clusters.yaml, each into .config/NAME/kubeconfig.
#
#   scripts/login.sh                         (make login) every cluster whose login doesn't work
#   scripts/login.sh NAME [oc login flags]   (make login NAME=...) one cluster
#
# With no flags it runs oc login --web, which opens your browser. To use a
# kubeconfig you already have, such as the installer's auth/kubeconfig, copy it
# to .config/NAME/kubeconfig instead.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."

login() { # NAME [oc login flags]
  local name=$1 api k; shift
  api=$(cluster_field "$name" api) || return 1
  k=$(cluster_kubeconfig "$name")
  mkdir -p "$(dirname "$k")"; chmod 700 "$(dirname "$k")"
  [ $# -gt 0 ] || set -- --web
  echo "Logging in to $name ($api)."
  KUBECONFIG=$k oc login --server "$api" "$@"
  chmod 600 "$k"
  echo "Logged in to $name as $(KUBECONFIG=$k oc whoami)."
}

if [ $# -ge 1 ]; then login "$@"; exit; fi
for name in $(hub_name) $(site_names); do
  if cluster_login_ok "$name" 2>/dev/null; then echo "$name: already logged in."; else login "$name"; fi
done
