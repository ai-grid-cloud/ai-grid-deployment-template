#!/usr/bin/env bash
# Check a site before it joins ACM (install guide, page 5; make site-check).
# Read only. Runs check-prerequisites.sh --step spoke (OpenShift version, a
# default StorageClass, a previous AI Grid install), then checks that the
# site's apps domain resolves (router-default.APPS_DOMAIN), and that the site
# doesn't run the platform's cert-manager operator: on the library's main
# branch OpenShift AI's chart then adds a second OperatorGroup in
# cert-manager-operator and OLM fails the operator (TooManyOperatorGroups;
# docs/upstream-main-limits.md), and that the import can give the site its two
# Submariner gateway nodes (scripts/gateway-nodes.sh --dry-run). On a site with
# GPU nodes, it warns when the GPU stack (NFD's NodeFeatureDiscovery, the GPU
# Operator's ClusterPolicy) is missing: on the library's main branch the
# platform provides it.
#
#   scripts/site-check.sh [NAME]     NAME defaults to the only site in clusters.yaml
#
# Prints OK, MISSING, FOUND or WARN per check, and exits 1 if anything is
# MISSING or FOUND.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
name=$(site_name "${1:-}")
cluster_login_ok "$name"
rc=0
"$here/check-prerequisites.sh" --step spoke --cluster "$name" || rc=1
domain=$(KUBECONFIG=$(cluster_kubeconfig "$name") oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
if python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], 443)' "router-default.$domain" 2>/dev/null; then
  printf '%-8s %-40s %s\n' OK "apps domain DNS" "router-default.$domain resolves"
else
  printf '%-8s %-40s %s\n' MISSING "apps domain DNS" "router-default.$domain doesn't resolve: check the cluster's DNS"
  rc=1
fi
# The chart's OperatorGroup is openshift-cert-manager-operator, but so is the
# platform's CLI install's, so the name alone isn't the chart's. The hub's Argo
# CD tracks what the chart deploys for the site's Application, which the
# library's apps/rhoai/hub/01-applicationset.yaml names
# rhoai-<name, first 34>-<sha256 of name, first 8>: the label
# app.kubernetes.io/instance or the annotation argocd.argoproj.io/tracking-id
# (APP:GROUP/KIND:NS/NAME). Removing a site preserves its resources, so a rejoin
# finds the same tracking. One tracked by another rhoai- Application (an
# earlier hub, or a cluster renamed since) can't be told apart: WARN.
chart_og=openshift-cert-manager-operator
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
site_app="rhoai-${name:0:34}-$(printf '%s' "$name" | sha256 | cut -c1-8)"
# stderr apart: an oc Warning: line isn't an OperatorGroup.
og_err=$(mktemp); trap 'rm -f "$og_err"' EXIT
if ! ogs=$(KUBECONFIG=$(cluster_kubeconfig "$name") oc get operatorgroups.operators.coreos.com -n cert-manager-operator \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.app\.kubernetes\.io/instance}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' 2>"$og_err"); then
  printf '%-8s %-40s %s\n' MISSING "cert-manager OperatorGroup" "can't read OperatorGroups in cert-manager-operator: $(tail -n1 "$og_err")"
  rc=1
else
  other="" unsure="" ours=""
  while IFS='|' read -r og label ann; do
    [ -n "$og" ] || continue
    app=${ann%%:*}
    if [ "$og" = "$chart_og" ] && { [ "$app" = "$site_app" ] || [ "$label" = "$site_app" ]; }; then ours=$og
    elif [ "$og" = "$chart_og" ] && { [[ "$app" == rhoai-* ]] || [[ "$label" == rhoai-* ]]; }; then unsure="$og (tracked by ${app:-$label})"
    else [ -n "$other" ] || other=$og; fi
  done <<<"$ogs"
  if [ -n "$other" ]; then
    printf '%-8s %-40s %s\n' FOUND "cert-manager OperatorGroup" "$other: the platform runs cert-manager here, and OpenShift AI's chart would add a second OperatorGroup (TooManyOperatorGroups). On the library's main branch this site can't join (docs/upstream-main-limits.md)"
    rc=1
  elif [ -n "$unsure" ]; then
    printf '%-8s %-40s %s\n' WARN "cert-manager OperatorGroup" "$unsure, not this site's $site_app: left by an earlier join, or the platform's; if this site never joined a grid, it's the platform's and the site can't join (docs/upstream-main-limits.md)"
  elif [ -n "$ours" ]; then
    printf '%-8s %-40s %s\n' OK "cert-manager OperatorGroup" "OpenShift AI's chart's, from $site_app"
  else
    printf '%-8s %-40s %s\n' OK "cert-manager OperatorGroup" "none: OpenShift AI's chart adds its own"
  fi
fi
# Its Submariner gateway nodes: make site-import labels two workers, so this
# fails only when it couldn't (a compact cluster or single-node OpenShift).
if gw=$("$here/gateway-nodes.sh" --dry-run "$name" 2>&1); then
  printf '%-8s %-40s %s\n' OK "Submariner gateway nodes" "${gw#"$name: "}"
else
  printf '%-8s %-40s %s\n' MISSING "Submariner gateway nodes" "${gw#error: }"
  rc=1
fi
# GPU nodes: labelled by the GPU Operator or NFD (NVIDIA's PCI vendor 10de), or
# with a GPU capacity above zero.
o() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }
gpu_nodes=$( { o get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null
  o get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name 2>/dev/null
  o get nodes -o json 2>/dev/null | jq -r '.items[] | select((.status.capacity["nvidia.com/gpu"] // "0" | tonumber? // 0) > 0) | .metadata.name'
  true; } | sed 's#^node/##' | awk 'NF' | sort -u | wc -l | tr -d ' ')
if [ "$gpu_nodes" = 0 ]; then
  printf '%-8s %-40s %s\n' OK "GPU stack" "no GPU nodes"
else
  gaps=()
  [ -n "$(o get clusterpolicies.nvidia.com -o name 2>/dev/null || true)" ] || gaps+=("no ClusterPolicy")
  [ -n "$(o get nodefeaturediscoveries.nfd.openshift.io -A -o name 2>/dev/null || true)" ] || gaps+=("no NodeFeatureDiscovery")
  if [ ${#gaps[@]} -eq 0 ]; then
    printf '%-8s %-40s %s\n' OK "GPU stack" "$gpu_nodes GPU node(s), a ClusterPolicy and a NodeFeatureDiscovery"
  else
    printf '%-8s %-40s %s\n' WARN "GPU stack" "$gpu_nodes GPU node(s) but $(IFS=,; echo "${gaps[*]}" | sed 's/,/, /g'): the GPU stack (NFD, GPU Operator, ClusterPolicy) is a site prerequisite; the library's main branch doesn't install it"
  fi
fi
exit "$rc"
