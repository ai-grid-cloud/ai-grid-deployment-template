#!/usr/bin/env bash
# Reads the clusters file at the root of a deployment repository: one line per
# cluster, four columns, # starts a comment.
#
#   name      role                                 location   api
#   hub       hub                                  -          https://api.hub.example.com:6443
#   site-b    combined | ingress | inference       us-east    https://api.site-b.example.com:6443
#
# Each cluster's login is .config/NAME/kubeconfig (git-ignored; make login NAME=...).
# Sourced by the other scripts:
#   clusters_load DIR             reads and checks DIR/clusters
#   hub_name, site_names          the hub's name; the sites' names
#   cluster_field NAME FIELD      role, location or api
#   cluster_kubeconfig NAME       the path of NAME's kubeconfig
#   merge_kubeconfigs HUB SITE OUT  one kubeconfig with contexts hub and site

CLUSTERS_DIR="" CLUSTERS_ROWS=""

clusters_load() {
  CLUSTERS_DIR=$(cd "${1:-.}" && pwd)
  local f="$CLUSTERS_DIR/clusters" rows="" line n=0 hubs=0 name role location api extra
  [ -f "$f" ] || { echo "error: no clusters file in $CLUSTERS_DIR" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line=${line%%#*}
    [ -n "${line//[[:space:]]/}" ] || continue
    read -r name role location api extra <<<"$line"
    [ -n "$api" ] && [ -z "$extra" ] || { echo "error: clusters line $n needs 4 columns: name role location api" >&2; return 1; }
    case "$line" in *REQUIRED-*) echo "error: clusters line $n still has a placeholder: $(grep -oE 'REQUIRED-[A-Za-z]+' <<<"$line" | tr '\n' ' ')" >&2; return 1 ;; esac
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "error: clusters line $n: name $name isn't a DNS label" >&2; return 1; }
    case "$role" in
      hub) hubs=$((hubs+1)) ;;
      combined|ingress|inference) ;;
      *) echo "error: clusters line $n: role $role isn't hub, combined, ingress or inference" >&2; return 1 ;;
    esac
    [[ "$api" =~ ^https:// ]] || { echo "error: clusters line $n: api $api isn't an https URL" >&2; return 1; }
    rows+="$name $role $location $api"$'\n'
  done < "$f"
  [ "$hubs" = 1 ] || { echo "error: the clusters file needs exactly one hub, found $hubs" >&2; return 1; }
  CLUSTERS_ROWS=$rows
}

hub_name() { awk '$2 == "hub" {print $1}' <<<"$CLUSTERS_ROWS"; }
site_names() { awk '$2 != "hub" && NF {print $1}' <<<"$CLUSTERS_ROWS"; }

cluster_field() { # NAME role|location|api
  local col
  case "$2" in role) col=2 ;; location) col=3 ;; api) col=4 ;; *) echo "error: unknown field $2" >&2; return 1 ;; esac
  local v; v=$(awk -v n="$1" -v c="$col" '$1 == n {print $c}' <<<"$CLUSTERS_ROWS")
  [ -n "$v" ] || { echo "error: no cluster $1 in $CLUSTERS_DIR/clusters" >&2; return 1; }
  echo "$v"
}

cluster_kubeconfig() { cluster_field "$1" role >/dev/null && echo "$CLUSTERS_DIR/.config/$1/kubeconfig"; }

cluster_login_ok() { # NAME: exits non-zero, with the fix, when there's no working login
  local k; k=$(cluster_kubeconfig "$1") || return 1
  [ -f "$k" ] || { echo "error: no login for $1: run make login NAME=$1" >&2; return 1; }
  KUBECONFIG=$k oc whoami >/dev/null 2>&1 || { echo "error: $1: login expired: run make login NAME=$1" >&2; return 1; }
}

merge_kubeconfigs() { # HUB SITE OUT: renames each cluster, user and context, so equal names in the two files can't collide
  local out=$3 alias name tmp; tmp=$(mktemp -d); : > "$out"; chmod 600 "$out"
  for alias in hub site; do
    if [ "$alias" = hub ]; then name=$1; else name=$2; fi
    KUBECONFIG=$(cluster_kubeconfig "$name") oc config view --raw --flatten --minify -o json |
      jq --arg a "$alias" '.clusters[0].name = $a | .users[0].name = $a
        | .contexts[0].name = $a | .contexts[0].context.cluster = $a | .contexts[0].context.user = $a
        | .["current-context"] = $a' > "$tmp/$alias.json" || { rm -rf "$tmp"; return 1; }
  done
  KUBECONFIG="$tmp/hub.json:$tmp/site.json" oc config view --raw --flatten > "$out"
  rm -rf "$tmp"
}
