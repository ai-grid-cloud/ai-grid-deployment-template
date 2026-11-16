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
[ ! -f "$d/oc-error" ] || { cat "$d/oc-error" >&2; exit 1; }
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
  *" get multiclusterhub "*) ans mch ;;
  *" get route "*) ans route ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

# The stub curl prints $STUB_DIR/curl.code as the HTTP code; with code 000 it
# prints $STUB_DIR/curl.err to stderr and fails, as curl does.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/curl.log"
code=$(cat "$STUB_DIR/curl.code"); printf '%s' "$code"
[ "$code" != 000 ] || { cat "$STUB_DIR/curl.err" >&2; exit 6; }
STUB
chmod +x "$T/bin/curl"

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

W="$T/strict"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app limitador-redis Synced Progressing)]}" > "$W/apps.1"
echo '{"items":[]}' > "$W/placements.1"
t "apps_healthy --strict: a site-waiting app blocks and is named" 1 \
  "^gate ready: FAILED after [0-9]+s: .*limitador-redis \(Synced Progressing\)" "" "gate ready 0 apps_healthy --strict"

W="$T/ocerr"; mkdir -p "$W"
echo "error: You must be logged in to the server (Unauthorized)" > "$W/oc-error"
t "oc error: FAILED early with oc's reason" 1 \
  $'^gate g: FAILED after [0-9]+s: oc error: error: You must be logged in to the server \\(Unauthorized\\)$\n^calls=4$' \
  "not created yet" 'gate g 30 app_healthy g; rc=$?; echo "calls=$(wc -l < "$STUB_DIR/argv.log" | tr -d " ")"; exit $rc'

W="$T/waits"; mkdir -p "$W"
for i in 1 2 3 4 5 6; do app g Synced Progressing > "$W/app.$i"; done; app g Synced Healthy > "$W/app.7"
t "not ready: still waits past the error limit" 0 "^gate g: passed after [0-9]+s$" "FAILED" "gate g 100000 app_healthy g"

W="$T/cleared"; mkdir -p "$W"
app g Synced Healthy > "$W/app.1"
t "a passing gate clears failed-gate" 0 "^cleared$" "" \
  'mkdir -p .install && echo old > .install/failed-gate && gate g 60 app_healthy g && [ ! -e .install/failed-gate ] && echo cleared'

SHA=0123456789abcdef0123456789abcdef01234567 OTHER=fedcba9876543210fedcba9876543210fedcba98
root() { printf '{"metadata":{"name":"deployment-root"},"status":{"sync":{"status":"%s"%s}}}' "$@"; }
W="$T/root-rev"; mkdir -p "$W"; root Synced ",\"revision\":\"$SHA\"" > "$W/app.1"
t "root_synced_to: match on revision" 0 "^gate root: passed" "" "gate root 0 root_synced_to $SHA"
W="$T/root-revs"; mkdir -p "$W"; root Synced ",\"revisions\":[\"$OTHER\",\"$SHA\"]" > "$W/app.1"
t "root_synced_to: match within revisions" 0 "^gate root: passed" "" "gate root 0 root_synced_to $SHA"
W="$T/root-miss"; mkdir -p "$W"; root Synced ",\"revision\":\"$OTHER\"" > "$W/app.1"
t "root_synced_to: mismatch" 1 "^gate root: FAILED.*Synced at $OTHER, not Synced at $SHA" "" "gate root 0 root_synced_to $SHA"

W="$T/mch-run"; mkdir -p "$W"; echo '{"items":[{"status":{"phase":"Running"}}]}' > "$W/mch.1"
t "mch_running: Running" 0 "^gate mch: passed" "" "gate mch 0 mch_running"
W="$T/mch-inst"; mkdir -p "$W"; echo '{"items":[{"status":{"phase":"Installing"}}]}' > "$W/mch.1"
t "mch_running: Installing" 1 "^gate mch: FAILED.*MultiClusterHub: Installing" "" "gate mch 0 mch_running"

route() { mkdir -p "$W"; echo '{"spec":{"host":"console.example.com"}}' > "$W/route.1"; echo "$1" > "$W/curl.code"; }
W="$T/route-302"; route 302
t "route_answers: 302 passes" 0 "^gate console: passed" "" "gate console 0 route_answers ns console"
W="$T/route-503"; route 503
t "route_answers: 503 fails" 1 "^gate console: FAILED.*answered 503" "" "gate console 0 route_answers ns console"
W="$T/route-000"; route 000; echo "curl: (6) Could not resolve host: console.example.com" > "$W/curl.err"
t "route_answers: 000 fails with curl's error" 1 \
  "^gate console: FAILED.*https://console.example.com/ answered 000: curl: \(6\) Could not resolve host: console.example.com$" \
  "" "gate console 0 route_answers ns console"

total=$((total+1))
if grep -qE -- '(^| )-k( |$)|--insecure' "$T"/*/curl.log; then fails=$((fails+1)); echo "   FAIL curl ran with -k"
else echo "   ok   curl never runs with -k"; fi

total=$((total+1))
if out=$(bash tests/status-test.sh 2>&1); then echo "   ok   status.sh still passes"
else fails=$((fails+1)); echo "   FAIL status.sh still passes (output:)"; echo "$out"; fi

total=$((total+1))
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale|rollout' "$T"/*/argv.log; then
  fails=$((fails+1)); echo "   FAIL oc got a write verb"; else echo "   ok   oc calls are read-only"; fi

echo "gates tests: $((total-fails)) ok, $fails failed"; exit "$fails"
