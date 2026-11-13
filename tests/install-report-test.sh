#!/usr/bin/env bash
# Tests for scripts/install-report.sh against a stub oc that answers from files.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_greps reject_grep [GATE]: runs install-report.sh in $D with the stub oc reading $W;
       # every line of expect_greps must match the output
  local name=$1 want=$2 expect=$3 reject=$4 rc out ok=1 e; shift 4
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/install-report.sh" "$@" 2>&1) && rc=0 || rc=$?
  [ "$rc" = "$want" ] || ok=""
  while IFS= read -r e; do grep -qE -- "$e" <<<"$out" || ok=""; done <<<"$expect"
  [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out" || ok=""
  if [ -n "$ok" ]; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The stub oc logs its arguments and answers from files in $STUB_DIR; a missing
# file is an error, as for a resource that doesn't exist.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; a=" $* "
ans() { [ -f "$d/$1" ] || { echo "NotFound" >&2; exit 1; }; cat "$d/$1"; }
case "$a" in
  *" whoami --show-server "*) echo https://api.hub.example.com:6443 ;;
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io -n openshift-gitops "*) ans apps.json ;;
  *" get managedcluster "*|*" get managedclusters."*) ans mc.json ;;
  *) echo "NotFound" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/oc"

D="$T/repo"; mkdir -p "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"

# An Application stuck on a condition, a failed sync and a Degraded resource.
W="$T/stuck"; mkdir -p "$W"
cat > "$W/apps.json" <<'JSON'
{"items":[
 {"metadata":{"name":"acm"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},
 {"metadata":{"name":"console"},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Degraded"},
  "conditions":[{"type":"ComparisonError","message":"STUCK-CONDITION-MESSAGE"}],
  "operationState":{"phase":"Failed","message":"STUCK-OPERATION-MESSAGE"},
  "resources":[{"kind":"Deployment","namespace":"ai-grid-provider-console","name":"web","health":{"status":"Degraded","message":"STUCK-RESOURCE-MESSAGE"}},
   {"kind":"Service","namespace":"ai-grid-provider-console","name":"web","health":{"status":"Healthy"}}]}}]}
JSON
cat > "$W/mc.json" <<'JSON'
{"metadata":{"name":"site-b"},"status":{"conditions":[{"type":"ManagedClusterJoined","status":"True","message":"joined"},
 {"type":"ManagedClusterConditionAvailable","status":"Unknown","message":"MC-NOT-AVAILABLE-MESSAGE"}]}}
JSON
mkdir -p "$D/.install"; echo hub-apps > "$D/.install/failed-gate"
t "app gate: names the gate and the stuck app's message" 0 $'^FAILED GATE: hub-apps$\nSTUCK-CONDITION-MESSAGE\nSTUCK-OPERATION-MESSAGE\nDeployment ai-grid-provider-console/web: Degraded: STUCK-RESOURCE-MESSAGE' \
  "== site-b on the hub|Service ai-grid-provider-console/web|^Application acm"

t "site gate: includes site-status" 0 $'^FAILED GATE: site-site-b-import$\n^== site-b on the hub \\(hub\\)$\nMC-NOT-AVAILABLE-MESSAGE' "" site-site-b-import

rm -f "$D/.install/failed-gate"
t "no failed gate: says so" 0 "^no failed gate recorded" "FAILED GATE"

echo hub-apps > "$D/.install/failed-gate"
total=$((total+1))
out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/install-report.sh" 2>&1) || true
if [ -n "$out" ] && [ "$out" = "$(cat "$D/.install/report.txt" 2>/dev/null)" ]; then echo "   ok   report.txt written"
else fails=$((fails+1)); echo "   FAIL report.txt written (stdout and .install/report.txt differ)"; fi

total=$((total+1))
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale|rollout|secrets?' "$T"/*/argv.log; then
  fails=$((fails+1)); echo "   FAIL oc got a write verb or read a Secret"; else echo "   ok   oc calls are read-only and read no Secret"; fi

echo "install-report tests: $((total-fails)) ok, $fails failed"; exit "$fails"
