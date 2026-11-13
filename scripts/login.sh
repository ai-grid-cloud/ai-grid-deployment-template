#!/usr/bin/env bash
# Log in to the clusters in clusters.yaml, each into .config/NAME/kubeconfig.
#
#   scripts/login.sh                         (make login) every cluster whose login doesn't work
#   scripts/login.sh NAME [oc login flags]   (make login NAME=...) one cluster; NAME=site is the only site
#
#   scripts/login.sh --non-interactive [NAME]   every cluster, or NAME, with no browser
#
# With no flags it runs oc login --web, which opens your browser. To use a
# kubeconfig you already have, such as the installer's auth/kubeconfig, copy it
# to .config/NAME/kubeconfig instead.
#
# --non-interactive never opens a browser or asks a question; make install uses
# it. For each cluster it keeps a working .config/NAME/kubeconfig as it is.
# Otherwise it reads a token from the file .config/NAME/token, or else from the
# environment variable AI_GRID_TOKEN_<NAME> (NAME upper-cased, - turned into _),
# and writes .config/NAME/kubeconfig (mode 600) with that token and the API URL
# from clusters.yaml. The cluster's certificate is checked against the system's
# CA trust. The token is read and written by shell builtins only, so it never
# appears in a command line or in the output. With no working login and no
# token, it stops with exit 1 and names the file to create.
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

token_login() { # NAME: writes NAME's kubeconfig from its token file or variable, then checks it
  local name=$1 api k dir tf var token="" tmp
  api=$(cluster_field "$name" api) || return 1
  k=$(cluster_kubeconfig "$name"); dir=$(dirname "$k"); tf="$dir/token"
  var=AI_GRID_TOKEN_$(tr 'a-z-' 'A-Z_' <<<"$name")
  if [ -f "$tf" ]; then
    IFS= read -r token < "$tf" || true
    [ -n "$token" ] || { echo "error: $name: $tf is empty: put the cluster's token in it" >&2; return 1; }
  elif [ -n "${!var:-}" ]; then
    token=${!var}
  else
    echo "error: $name: no working login and no token: put the cluster's token in $tf, or set $var" >&2
    return 1
  fi
  # A token is one word of these characters (OpenShift sha256~ tokens and JWTs
  # are); anything else could break the YAML, so stop without printing it.
  [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] ||
    { echo "error: $name: the token from ${tf} or $var isn't a single word; check it" >&2; return 1; }
  mkdir -p "$dir"; chmod 700 "$dir"
  tmp="$k.new"; rm -f "$tmp"
  ( umask 077; printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: %s\n  cluster:\n    server: %s\ncontexts:\n- name: %s\n  context:\n    cluster: %s\n    user: %s\ncurrent-context: %s\nusers:\n- name: %s\n  user:\n    token: %s\n' \
      "$name" "$api" "$name" "$name" "$name" "$name" "$name" "$token" > "$tmp" )
  chmod 600 "$tmp"
  if ! KUBECONFIG=$tmp oc whoami >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "error: $name: the token from $([ -f "$tf" ] && echo "$tf" || echo "$var") doesn't log in to $api: replace it" >&2
    return 1
  fi
  mv -f "$tmp" "$k"
  echo "Logged in to $name as $(KUBECONFIG=$k oc whoami)."
}

if [ "${1:-}" = --non-interactive ]; then
  shift
  if [ $# -ge 1 ]; then names=$1; else names="$(hub_name) $(site_names)"; fi
  rc=0
  for name in $names; do
    if cluster_login_ok "$name" 2>/dev/null; then echo "$name: already logged in."; else token_login "$name" || rc=1; fi
  done
  exit "$rc"
fi

if [ $# -ge 1 ]; then
  name=$1; shift
  login "$name" "$@"; exit
fi
for name in $(hub_name) $(site_names); do
  if cluster_login_ok "$name" 2>/dev/null; then echo "$name: already logged in."; else login "$name"; fi
done
