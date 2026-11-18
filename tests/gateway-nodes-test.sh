#!/usr/bin/env bash
# Tests for scripts/gateway-nodes.sh, which labels a cluster's Submariner
# gateway nodes, with a stub oc that answers get nodes from $STUB_DIR/nodes.json
# and logs every oc label to $STUB_DIR/label.log (no cluster).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
t() { # name want_rc expect_grep reject_grep labels_want [args...]: labels_want is label.log's content, one line
  local name=$1 want=$2 expect=$3 reject=$4 lw=$5; shift 5; local rc out got
  total=$((total+1)); : > "$T/label.log"
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" "$D/scripts/gateway-nodes.sh" "$@" 2>&1) && rc=0 || rc=$?
  got=$(tr '\n' ';' < "$T/label.log")
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; } &&
      [ "$got" = "$lw" ]; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; labels: '$got', wanted '$lw'; output:)"; echo "$out"; fi
}
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
case " $* " in
  *" get nodes -o json "*)
    [ ! -f "$STUB_DIR/get.err" ] || { cat "$STUB_DIR/get.err" >&2; exit 1; }
    cat "$STUB_DIR/nodes.json" ;;
  *" label node "*)
    [ ! -f "$STUB_DIR/label.err" ] || { cat "$STUB_DIR/label.err" >&2; exit 1; }
    [ ! -f "$STUB_DIR/label-fail-$3" ] || { echo "Error from server (Forbidden): nodes \"$3\" is forbidden" >&2; exit 1; }
    echo "$KUBECONFIG ${*:3}" >> "$STUB_DIR/label.log" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"
D="$T/repo"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
for n in hub site-b; do mkdir -p "$D/.config/$n"; : > "$D/.config/$n/kubeconfig"; done
KC="$D/.config/site-b/kubeconfig"

node() { # NAME ROLES(comma-separated) [ready=True] [unschedulable=false] [gateway label value, or empty]
  local name=$1 roles=$2 ready=${3:-True} unsched=${4:-false} gw=${5:-}
  jq -cn --arg n "$name" --arg r "$roles" --arg ready "$ready" --argjson u "$unsched" --arg gw "$gw" '
    {metadata: {name: $n, labels: (($r | split(",") | map({key: "node-role.kubernetes.io/\(.)", value: ""}) | from_entries)
       + (if $gw == "" then {} else {"submariner.io/gateway": $gw} end))},
     spec: {unschedulable: $u}, status: {conditions: [{type: "Ready", status: $ready}]}}'
}
nodes() { jq -s '{items: .}' > "$T/nodes.json"; }

# A standard cluster: three control-plane nodes and three workers, none labelled.
{ node m1 control-plane,master; node m2 control-plane,master; node m3 control-plane,master
  node w3 worker; node w1 worker; node w2 worker; } | nodes
t "none labelled: labels two workers, by name" 0 "^site-b: labelled w1, w2 submariner.io/gateway=true" "" \
  "$KC w1 submariner.io/gateway=true;$KC w2 submariner.io/gateway=true;" site-b
t "--kubeconfig: uses that login" 0 "^hub: labelled w1, w2" "" "$T/kc w1 submariner.io/gateway=true;$T/kc w2 submariner.io/gateway=true;" --kubeconfig "$T/kc" hub
t "--dry-run: says what it would label, labels nothing" 0 "^site-b: would label w1, w2 submariner.io/gateway=true" "" "" --dry-run site-b

{ node m1 control-plane,master; node w1 worker "" "" true; node w2 worker; node w3 worker "" "" true; } | nodes
t "two labelled already: no change" 0 "^site-b: Submariner gateway nodes already labelled: w1, w3\.$" "" "" site-b

{ node m1 control-plane,master; node w1 worker; node w2 worker "" "" true; node w3 worker; } | nodes
t "one labelled: labels one more" 0 "^site-b: labelled w1 .*\(already labelled: w2\)" "" "$KC w1 submariner.io/gateway=true;" site-b

{ node w1 worker False; node w2 worker True true; node w3 worker; node w4 worker True false false; node w5 worker; } | nodes
t "skips NotReady, unschedulable, and a node set to false" 0 "labelled w3, w5" "" "$KC w3 submariner.io/gateway=true;$KC w5 submariner.io/gateway=true;" site-b

{ node a-infra infra,worker; node m1 control-plane,master,worker; node z-w worker; } | nodes
t "only-worker nodes first, then workers with another role; never the control plane" 0 "labelled z-w, a-infra" "" \
  "$KC z-w submariner.io/gateway=true;$KC a-infra submariner.io/gateway=true;" site-b

# GPU nodes: nvidia.com/gpu capacity or allocatable above zero, or nvidia.com/gpu.present=true.
gpu() { jq -c "$1"; }
{ node a-gpu worker | gpu '.status.capacity = {"nvidia.com/gpu": "1"}'
  node b-gpu worker | gpu '.status.allocatable = {"nvidia.com/gpu": "2"}'
  node c-gpu worker | gpu '.metadata.labels["nvidia.com/gpu.present"] = "true"'
  node y-cpu worker | gpu '.status.capacity = {"nvidia.com/gpu": "0"}'; node z-cpu worker; } | nodes
t "skips GPU workers while two others exist" 0 "^site-b: labelled y-cpu, z-cpu " "GPU" "$KC y-cpu submariner.io/gateway=true;$KC z-cpu submariner.io/gateway=true;" site-b
{ node a-gpu worker | gpu '.status.capacity = {"nvidia.com/gpu": "1"}'
  node c-gpu worker | gpu '.metadata.labels["nvidia.com/gpu.present"] = "true"'
  node z-cpu worker; node m1 control-plane,master; } | nodes
t "one worker without GPUs: adds a GPU node, and says so" 0 "labelled z-cpu, a-gpu .*uses GPU nodes too: a-gpu\.$" "" \
  "$KC z-cpu submariner.io/gateway=true;$KC a-gpu submariner.io/gateway=true;" site-b
{ node a-gpu worker | gpu '.status.capacity = {"nvidia.com/gpu": "1"}'
  node c-gpu worker | gpu '.metadata.labels["nvidia.com/gpu.present"] = "true"'; } | nodes
t "only GPU workers: labels two of them, and says so" 0 "labelled a-gpu, c-gpu .*uses GPU nodes too: a-gpu, c-gpu\.$" "" \
  "$KC a-gpu submariner.io/gateway=true;$KC c-gpu submariner.io/gateway=true;" site-b
t "  ... --dry-run says so too" 0 "would label a-gpu, c-gpu .*uses GPU nodes too" "" "" --dry-run site-b

{ node m1 control-plane,master,worker; node m2 control-plane,master,worker; node m3 control-plane,master,worker; } | nodes
t "compact cluster: labels nothing, names the command" 1 \
  "^error: site-b needs two Submariner gateway nodes, has 0 labelled .*: label 2 yourself .*KUBECONFIG=$KC oc label node m1 m2 submariner.io/gateway=true$" "" "" site-b
t "  ... --dry-run fails the same way" 1 "label 2 yourself" "" "" --dry-run site-b

{ node w1 worker; node m1 control-plane,master,worker; } | nodes
t "one worker, the rest control plane: labels nothing, names one more" 1 "has 0 labelled .*oc label node w1 m1 submariner.io/gateway=true$" "" "" site-b

{ node sno control-plane,master,worker; } | nodes
t "single-node OpenShift: needs one, names the node" 1 "needs one Submariner gateway node, has 0 labelled .*oc label node sno submariner.io/gateway=true$" "" "" site-b
{ node sno control-plane,master,worker "" "" true; } | nodes
t "  ... labelled by hand: OK" 0 "already labelled: sno\.$" "" "" site-b

{ node w1 worker False; node w2 worker False; } | nodes
t "no Ready node: fails, says so" 1 "no Ready, schedulable node is left to label" "" "" site-b

{ node w1 worker; node w2 worker; } | nodes
printf 'error: You must be logged in to the server (Unauthorized)\n' > "$T/get.err"
t "oc get fails: exit 1, not silent" 1 "^error: site-b: can't read its nodes .*Unauthorized" "" "" site-b
rm "$T/get.err"
printf 'Error from server (Forbidden): nodes "w1" is forbidden\n' > "$T/label.err"
t "oc label fails: exit 1, not silent" 1 "^error: site-b: labelling w1 submariner.io/gateway=true failed: .*Forbidden" "" "" site-b
rm "$T/label.err"
touch "$T/label-fail-w2"
t "oc label fails on the second node: names it, and the one done" 1 "^error: site-b: labelling w2 submariner.io/gateway=true failed \(labelled already: w1\): .*\"w2\" is forbidden" "" \
  "$KC w1 submariner.io/gateway=true;" site-b
rm "$T/label-fail-w2"

{ node w1 worker False "" true; node w2 worker True true true; node w3 worker; } | nodes
t "labelled but NotReady or cordoned: still counted, with a warning" 0 \
  "warning: site-b: Submariner gateway node\(s\) w1, w2 are NotReady or cordoned" "" "" site-b
t "  ... and labels nothing" 0 "already labelled: w1, w2\.$" "" "" site-b

{ node i1 infra; node i2 infra; node m1 control-plane,master; } | nodes
t "infra-only nodes (no worker role): labels nothing, names them" 1 "has 0 labelled .*oc label node i1 i2 submariner.io/gateway=true$" "" "" site-b

t "an unknown cluster: exit 1" 1 "no cluster nope" "" "" nope

echo "gateway-nodes tests: $((total-fails)) ok, $fails failed"; exit "$fails"
