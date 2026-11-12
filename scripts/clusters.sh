#!/usr/bin/env bash
# Reads clusters.yaml at the root of a deployment repository (copied from
# clusters-example.yaml): the hub, and each site with its role, location and
# API URL. Each cluster's login is .config/NAME/kubeconfig (git-ignored; make
# login). kubectl parses the YAML offline (--local), and jq reads the result.
#
# Sourced by the other scripts:
#   clusters_load DIR             reads and checks DIR/clusters.yaml
#   hub_name, site_names          the hub's name; the sites' names
#   site_name [NAME]              NAME, or the only site when NAME is empty or
#                                 "site"; with several sites, asks you to name one
#   cluster_field NAME FIELD      role, location or api
#   cluster_kubeconfig NAME       the path of NAME's kubeconfig
#   merge_kubeconfigs HUB SITE OUT  one kubeconfig with contexts hub and site

CLUSTERS_DIR="" CLUSTERS_ROWS=""

clusters_load() {
  CLUSTERS_DIR=$(cd "${1:-.}" && pwd)
  local f="$CLUSTERS_DIR/clusters.yaml" json rows="" what name role location api left
  [ -f "$f" ] || { echo "error: no clusters.yaml: copy clusters-example.yaml to clusters.yaml and edit it (install guide, page 2)" >&2; return 1; }
  json=$(KUBECONFIG=/dev/null kubectl label --local -f "$f" ai-grid.dev/read=true -o json 2>&1) ||
    { echo "error: clusters.yaml isn't valid: $json" >&2; return 1; }
  [ "$(jq -r .kind <<<"$json")" = Clusters ] || { echo "error: clusters.yaml needs kind: Clusters" >&2; return 1; }
  left=$(grep -oE 'REQUIRED-[A-Za-z]+' "$f" | sort -u | tr '\n' ' ' || true)
  [ -z "$left" ] || { echo "error: set these in clusters.yaml: ${left% }" >&2; return 1; }
  # One tab-separated row per cluster: what (hub or site N), name, role, location, api.
  while IFS=$'\t' read -r what name role location api; do
    [ -n "$name" ] && [ -n "$role" ] && [ -n "$location" ] && [ -n "$api" ] ||
      { echo "error: clusters.yaml: $what needs name$([ "$what" = hub ] || echo ', role, location') and api" >&2; return 1; }
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "error: clusters.yaml: $what name $name isn't a DNS label" >&2; return 1; }
    case "$what:$role" in
      hub:hub|site*:combined|site*:ingress|site*:inference) ;;
      *) echo "error: clusters.yaml: $what role $role isn't combined, ingress or inference" >&2; return 1 ;;
    esac
    [[ "$api" =~ ^https:// ]] || { echo "error: clusters.yaml: $what api $api isn't an https URL" >&2; return 1; }
    case " $(awk '{print $1}' <<<"$rows" | tr '\n' ' ') " in *" $name "*) echo "error: clusters.yaml: the name $name is used twice" >&2; return 1 ;; esac
    rows+="$name $role $location $api"$'\n'
  done < <(jq -r '(["hub", .hub.name, "hub", "-", .hub.api]),
      ((.sites // []) | to_entries[] | ["site \(.key + 1)", .value.name, .value.role, .value.location, .value.api])
      | map(. // "" | tostring) | @tsv' <<<"$json")
  [ -n "$rows" ] || { echo "error: clusters.yaml has no hub" >&2; return 1; }
  CLUSTERS_ROWS=$rows
}

hub_name() { awk '$2 == "hub" {print $1}' <<<"$CLUSTERS_ROWS"; }
site_names() { awk '$2 != "hub" && NF {print $1}' <<<"$CLUSTERS_ROWS"; }

site_name() { # [NAME]
  local n=${1:-} all count
  all=$(site_names)
  if [ -n "$n" ] && { [ "$n" != site ] || grep -qx site <<<"$all"; }; then echo "$n"; return 0; fi
  count=$(grep -c . <<<"$all" || true)
  case "$count" in
    1) echo "$all" ;;
    0) echo "error: clusters.yaml has no site" >&2; return 1 ;;
    *) echo "error: name a site: $(echo $all | sed 's/ /, /g')" >&2; return 1 ;;
  esac
}

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

# scripts/clusters.sh --rows DIR prints one line per cluster (name role location
# api), or the error; prereqs.py uses it. scripts/clusters.sh --site [NAME]
# prints site_name's answer for this repository.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --rows ]; then
  clusters_load "${2:-.}" && printf '%s' "$CLUSTERS_ROWS"
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --site ]; then
  clusters_load "$(dirname "$0")/.." && site_name "${2:-}"
fi
