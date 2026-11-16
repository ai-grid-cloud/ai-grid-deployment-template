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
  *" get "*) [ ! -f "$d/fail" ] || { echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; } ;;
esac
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

# oc fails: the report says it couldn't read, never "none" or "not created yet".
W="$T/unauth"; mkdir -p "$W"; : > "$W/fail"
t "oc error: says it can't read Applications" 0 $'could not read Applications: oc error: .*Unauthorized' "^none$" hub-apps
t "oc error: says it can't read the ManagedCluster" 0 $'could not read ManagedCluster site-b: oc error: .*Unauthorized' "^  not created yet$" site-site-b-import

# 25 stuck Applications, one with a 2000-character message, and limitador-redis,
# which waits for a site.
W="$T/many"; mkdir -p "$W"
long=$(printf 'x%.0s' $(seq 2000))
{ echo '{"items":['
  echo '{"metadata":{"name":"limitador-redis"},"status":{"sync":{"status":"Synced"},"health":{"status":"Progressing"}}},'
  for i in $(seq -w 1 24); do
    m=short; [ "$i" != 01 ] || m=$long
    echo "{\"metadata\":{\"name\":\"app-$i\"},\"status\":{\"sync\":{\"status\":\"OutOfSync\"},\"health\":{\"status\":\"Degraded\"},\"conditions\":[{\"type\":\"SyncError\",\"message\":\"$m\"}]}}$([ "$i" = 24 ] || echo ,)"
  done
  echo ']}'; } > "$W/apps.json"
t "many apps: lists 20, then +5 more" 0 $'^Application limitador-redis \\(Synced Progressing\\) \\(waits for a site\\)$\n^Application app-19 \n^\\+5 more not Synced and Healthy$\nx…$' "^Application app-20 " hub-apps
total=$((total+1))
out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/install-report.sh" hub-apps 2>&1) || true
if [ "$(grep -c '^Application ' <<<"$out")" = 20 ] && ! awk 'length > 600 { bad=1 } END { exit !bad }' <<<"$out"; then
  echo "   ok   many apps: 20 listed, no line over 600 characters"
else fails=$((fails+1)); echo "   FAIL many apps: 20 listed, no line over 600 characters"; fi

# No gate recorded: an existing report.txt is left as it was.
rm -f "$D/.install/failed-gate"; echo "EARLIER REPORT" > "$D/.install/report.txt"
W="$T/stuck"
t "no failed gate: says so (with a report.txt)" 0 "^no failed gate recorded" "FAILED GATE"
total=$((total+1))
if [ "$(cat "$D/.install/report.txt")" = "EARLIER REPORT" ]; then echo "   ok   no failed gate: report.txt unchanged"
else fails=$((fails+1)); echo "   FAIL no failed gate: report.txt unchanged"; fi

echo "install-report tests: $((total-fails)) ok, $fails failed"; exit "$fails"
