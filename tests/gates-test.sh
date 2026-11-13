#!/usr/bin/env bash
# Tests for scripts/gates.sh against a stub oc that answers from a numbered
# sequence of files, so a resource can change between calls.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_greps reject_grep script: sources gates.sh in $D and runs script with the stub oc reading $W;
       # every line of expect_greps must match the output
  local name=$1 want=$2 expect=$3 reject=$4 script=$5 rc out ok=1 e
  total=$((total+1))
  out=$(cd "$D" && env PATH="$T/bin:$PATH" STUB_DIR="$W" GATE_INTERVAL=0 \
    bash -c ". scripts/gates.sh && $script" 2>&1) && rc=0 || rc=$?
  [ "$rc" = "$want" ] || ok=""
  while IFS= read -r e; do grep -qE -- "$e" <<<"$out" || ok=""; done <<<"$expect"
  [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out" || ok=""
  if [ -n "$ok" ]; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The stub oc logs its arguments and answers KEY from $STUB_DIR/KEY.N on its
# Nth call for KEY, or from the highest-numbered file once the sequence ends;
# no file at all is an error, as for a resource that doesn't exist.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; a=" $* "
ans() {
  local n f last=""; n=$(( $(cat "$d/$1.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/$1.count"
  for f in $(ls "$d" | grep -E "^$1\.[0-9]+$" | sort -t. -k2 -n); do last=$f; [ "$f" = "$1.$n" ] && break; done
  [ -n "$last" ] || { echo "NotFound" >&2; exit 1; }; cat "$d/$last"
}
case "$a" in
  *" get applications.argoproj.io -n openshift-gitops "*) ans apps ;;
  *" get applications.argoproj.io "*) ans app ;;
  *" get placements."*) ans placements ;;
  *" get managedclusters."*) ans mc ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

D="$T/repo"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"
app() { printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s"},"health":{"status":"%s"}}}' "$@"; }

W="$T/becomes"; mkdir -p "$W"
app g Synced Progressing > "$W/app.1"; app g Synced Healthy > "$W/app.2"
t "app becomes healthy" 0 "^gate g: passed after [0-9]+s$" "FAILED" "gate g 60 app_healthy g"

W="$T/timeout"; mkdir -p "$W"
app g Synced Progressing > "$W/app.1"
t "timeout: FAILED and failed-gate written" 1 $'^gate g: FAILED after [0-9]+s: .*Progressing\n^failed-gate=g$' "passed" \
  'gate g 0 app_healthy g; rc=$?; echo "failed-gate=$(cat .install/failed-gate)"; exit $rc'

W="$T/site"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app limitador-redis Synced Progressing)]}" > "$W/apps.1"
echo '{"items":[]}' > "$W/placements.1"
t "apps_healthy: a site-waiting app doesn't block" 0 "^gate hub-apps: passed" "" "gate hub-apps 0 apps_healthy"

W="$T/degraded"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app console Synced Degraded),$(app limitador-redis Synced Progressing)]}" > "$W/apps.1"
echo '{"items":[]}' > "$W/placements.1"
t "apps_healthy: a Degraded app blocks and is named" 1 "^gate hub-apps: FAILED after [0-9]+s: .*console \(Synced Degraded\)" \
  "limitador-redis" "gate hub-apps 0 apps_healthy"

W="$T/mc"; mkdir -p "$W"
cat > "$W/mc.1" <<'JSON'
{"metadata":{"name":"site-b"},"status":{"conditions":[{"type":"HubAcceptedManagedCluster","status":"True"},
 {"type":"ManagedClusterJoined","status":"True"},{"type":"ManagedClusterConditionAvailable","status":"Unknown"}]}}
JSON
t "managedcluster_available: joined but not available" 1 "^gate site-b-import: FAILED.*ManagedClusterConditionAvailable is Unknown" \
  "ManagedClusterJoined is" "gate site-b-import 0 managedcluster_available site-b"

total=$((total+1))
if out=$(bash tests/status-test.sh 2>&1); then echo "   ok   status.sh still passes"
else fails=$((fails+1)); echo "   FAIL status.sh still passes (output:)"; echo "$out"; fi

total=$((total+1))
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale|rollout' "$T"/*/argv.log; then
  fails=$((fails+1)); echo "   FAIL oc got a write verb"; else echo "   ok   oc calls are read-only"; fi

echo "gates tests: $((total-fails)) ok, $fails failed"; exit "$fails"
