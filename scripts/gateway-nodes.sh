#!/usr/bin/env bash
# Give a cluster its Submariner gateway nodes: label two of its worker nodes
# submariner.io/gateway=true when fewer than two carry that label.
#
# The library's Submariner add-on asks for two gateways on every cluster, the
# hub included (apps/acm/submariner, gatewayConfig.gateways: 2), but only its
# cloud-prepare step labels nodes, and that needs cloud credentials the library
# never gives it (it logs "no CredentialsSecret"). The library's own labelling Policy
# (cluster-config/chart/templates/submariner-gateway-nodes.yaml) comes only with
# its lab root, which neither this template nor the library's dedicated-hub
# root selects. Without the labels a cluster runs no Submariner gateway, and the
# sites can't reach the hub's services (docs/upstream-main-limits.md, L21).
# scripts/bootstrap-hub.sh runs this for the hub, scripts/import-site.sh for a
# site, and scripts/site-check.sh with --dry-run.
#
#   scripts/gateway-nodes.sh [--dry-run] [--kubeconfig FILE] NAME
#
# NAME is the hub or a site in clusters.yaml; its login is .config/NAME/kubeconfig
# unless --kubeconfig names one. It labels Ready, schedulable nodes with the
# worker role and no control-plane or master role: nodes with only the worker
# role first, then other workers (infra), then GPU workers, each by name. A GPU
# node is used only when too few others exist, and the output says so. On
# single-node OpenShift one labelled node is enough, but the script never
# labels a control-plane node itself: as on a compact cluster, it labels nothing,
# stops and prints the oc label command to run. It never removes or changes a
# label: a node whose submariner.io/gateway is anything but true is left out. A
# labelled node that is NotReady or cordoned still counts, with a warning.
# --dry-run changes nothing and says what it would do.
#
# Exits 0 when the cluster has (or, with --dry-run, would have) its gateway
# nodes, 1 when it needs nodes labelled by hand or oc fails.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dry="" kc=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --kubeconfig) kc=$2; shift 2 ;;
    -*) echo "usage: gateway-nodes.sh [--dry-run] [--kubeconfig FILE] NAME" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# = 1 ] || { echo "usage: gateway-nodes.sh [--dry-run] [--kubeconfig FILE] NAME" >&2; exit 2; }
name=$1
if [ -z "$kc" ]; then
  . "$here/clusters.sh"
  clusters_load "$here/.."
  kc=$(cluster_kubeconfig "$name")
fi
label=submariner.io/gateway=true

nodes=$(KUBECONFIG=$kc oc get nodes -o json 2>&1) || {
  echo "error: $name: can't read its nodes to check the Submariner gateway nodes: $(tail -n1 <<<"$nodes")" >&2; exit 1; }
# One line per node: KIND NAME, KIND one of
#   labelled  submariner.io/gateway=true already
#   stale     also labelled, but NotReady or cordoned
#   worker    Ready, schedulable, unlabelled, its only role worker
#   mixed     as worker, with another role that isn't control-plane or master (infra)
#   gpu       as worker or mixed, on a GPU node (nvidia.com/gpu capacity or
#             allocatable above zero, or label nvidia.com/gpu.present=true)
#   other     Ready, schedulable, unlabelled, any other roles (a compact cluster's control plane)
# and one line "usable N": the Ready, schedulable nodes, labelled or not.
rows=$(jq -r '
  def roles: [.metadata.labels // {} | keys[] | select(startswith("node-role.kubernetes.io/")) | ltrimstr("node-role.kubernetes.io/")];
  def ready: any(.status.conditions[]?; .type == "Ready" and .status == "True");
  def usable: ready and (.spec.unschedulable != true);
  def gpus($f): ((.status[$f] // {})["nvidia.com/gpu"] // "0" | tostring | tonumber? // 0) > 0;
  def gpu: gpus("capacity") or gpus("allocatable") or ((.metadata.labels // {})["nvidia.com/gpu.present"] == "true");
  (.items | sort_by(.metadata.name)) as $n
  | ($n[] | (.metadata.labels // {})["submariner.io/gateway"] as $g
      | if $g == "true" then "labelled \(.metadata.name)", (if usable then empty else "stale \(.metadata.name)" end)
        elif $g != null or (usable | not) then empty
        elif (roles | index("worker")) and ((roles | index("control-plane")) or (roles | index("master")) | not) and gpu then "gpu \(.metadata.name)"
        elif roles == ["worker"] then "worker \(.metadata.name)"
        elif (roles | index("worker")) and ((roles | index("control-plane")) or (roles | index("master")) | not) then "mixed \(.metadata.name)"
        else "other \(.metadata.name)" end),
    "usable \([$n[] | select(usable)] | length)"' <<<"$nodes") || {
  echo "error: $name: can't parse its nodes" >&2; exit 1; }

list() { tr '\n' ' ' | sed 's/ *$//; s/ /, /g'; }
pick() { awk -v k="$1" '$1 == k {print $2}' <<<"$rows"; }
first() { awk -v n="$1" 'NR <= n'; } # as head -n, reading all its input (no SIGPIPE under pipefail)
labelled=$(pick labelled)
have=$(grep -c . <<<"$labelled" || true)
usable=$(pick usable)
stale=$(pick stale)
[ -z "$stale" ] || echo "warning: $name: Submariner gateway node(s) $(list <<<"$stale") are NotReady or cordoned; they still count as labelled, so check them, or label another worker $label" >&2
want=2 wanted="two Submariner gateway nodes"
[ "$usable" -ge 2 ] || want=1 wanted="one Submariner gateway node"

if [ "$have" -ge "$want" ]; then
  echo "$name: Submariner gateway nodes already labelled: $(list <<<"$labelled")."
  exit 0
fi
need=$((want - have))
# GPU workers last, so the gateways don't take GPU nodes while others are free.
candidates=$( { pick worker; pick mixed; pick gpu; } | first "$need")
got=$(grep -c . <<<"$candidates" || true)
gpu_used=$(grep -xF -f <(pick gpu; echo '-') <<<"$candidates" | list || true)
gpu_note=""
[ -z "$gpu_used" ] || gpu_note=" Too few workers without GPUs, so it uses GPU nodes too: $gpu_used."
if [ "$got" -lt "$need" ]; then
  # The nodes to suggest: the workers found, then nodes with other roles.
  others=$( { pick worker; pick mixed; pick gpu; pick other; } | first "$need")
  how="no Ready, schedulable node is left to label"
  [ -z "$others" ] || how="label $need yourself with its login, such as: KUBECONFIG=$kc oc label node $(tr '\n' ' ' <<<"$others")$label"
  echo "error: $name needs $wanted, has $have labelled${labelled:+ ($(list <<<"$labelled"))} and too few Ready worker nodes outside the control plane to label (a compact cluster or single-node OpenShift): $how" >&2
  exit 1
fi
if [ -n "$dry" ]; then
  echo "$name: would label $(list <<<"$candidates") $label for Submariner's gateways${labelled:+ (already labelled: $(list <<<"$labelled"))}.$gpu_note"
  exit 0
fi
# One node per call, so a failure names the node it failed on.
done_nodes=""
while read -r n; do
  out=$(KUBECONFIG=$kc oc label node "$n" "$label" 2>&1) || {
    echo "error: $name: labelling $n $label failed${done_nodes:+ (labelled already: $(list <<<"$done_nodes"))}: $(tail -n1 <<<"$out")" >&2; exit 1; }
  done_nodes+="$n"$'\n'
done <<<"$candidates"
echo "$name: labelled $(list <<<"$candidates") $label for Submariner's gateways${labelled:+ (already labelled: $(list <<<"$labelled"))}.$gpu_note"
