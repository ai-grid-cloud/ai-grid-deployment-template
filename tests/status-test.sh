#!/usr/bin/env bash
# Tests for scripts/status.sh against a stub oc that answers from files.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name expect_grep [reject_grep]: runs status.sh in $D with the stub oc reading $W
  local name=$1 expect=$2 reject=${3:-} rc out
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/status.sh" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 0 ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; }; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
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
  *" get applications.argoproj.io tenant-idp "*) ans tenant-idp ;;
  *" get applications.argoproj.io "*) ans apps.json ;;
  *" get multiclusterhub "*) ans mch ;;
  *" get pods "*) ans pods.json ;;
  *" get route "*) ans route ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

D="$T/repo"; mkdir -p "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"

app() { printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s"},"health":{"status":"%s"}}}' "$@"; }
pods() { # restarts [last-termination [waiting-reason]]
  local extra=""
  [ -z "${2:-}" ] || extra+=",\"lastState\":{\"terminated\":{\"reason\":\"$2\"}}"
  [ -z "${3:-}" ] || extra+=",\"state\":{\"waiting\":{\"reason\":\"$3\"}}"
  printf '{"items":[{"metadata":{"name":"openshift-gitops-server-1"}},{"metadata":{"name":"openshift-gitops-application-controller-0"},"status":{"containerStatuses":[{"restartCount":%s%s}]}}]}' "$1" "$extra"
}

# Fresh hub: nothing yet.
W="$T/fresh"; mkdir -p "$W"
t "fresh: no Applications" "^Applications: none yet$"
t "fresh: no MultiClusterHub" "^MultiClusterHub: not created yet$"
t "fresh: no controller pod" "^Argo CD controller: no pod yet$"
t "fresh: no tenant-idp" "^tenant-idp: not created yet$"
t "fresh: no console" "^Console: no Route yet$"

# Installing: some Applications not ready, and the controller OOMKilled.
W="$T/installing"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Progressing),$(app console Synced Healthy),$(app limitador-redis OutOfSync Degraded)]}" > "$W/apps.json"
printf 'Installing' > "$W/mch"
pods 3 OOMKilled CrashLoopBackOff > "$W/pods.json"
printf 'Synced Progressing' > "$W/tenant-idp"
t "lists the Applications not ready" "^  acm +Synced +Progressing$" "^  console "
t "counts them" "^Applications not Synced and Healthy \(2 of 3\):$"
t "marks the ones that wait for a site" "^  limitador-redis +OutOfSync +Degraded +\(waits for a site"
t "MultiClusterHub phase" "^MultiClusterHub: Installing$"
t "controller restarts and last termination" "^Argo CD controller: openshift-gitops-application-controller-0, 3 restarts, last termination OOMKilled$"
t "OOMKilled called out with the fix" "^  !! The controller failed .*OOMKilled.*troubleshooting"
t "tenant-idp state" "^tenant-idp: Synced Progressing$"
pods 2 Error CrashLoopBackOff > "$W/pods.json"
t "CrashLoopBackOff called out" "^  !! The controller failed .*CrashLoopBackOff"

# Done: everything ready, the controller healthy, the console up.
W="$T/done"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app tenant-idp Synced Healthy)]}" > "$W/apps.json"
printf 'Running' > "$W/mch"; pods 0 > "$W/pods.json"; printf 'Synced Healthy' > "$W/tenant-idp"
printf 'console.apps.hub.example.com' > "$W/route"
t "done: all Applications ready" "^Applications: all 2 Synced and Healthy$"
t "done: no warning" "^Argo CD controller: .*0 restarts, last termination -$" "!!"
t "done: console URL" "^Console: https://console.apps.hub.example.com$"
total=$((total+1))
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale|rollout' "$T"/*/argv.log; then
  fails=$((fails+1)); echo "   FAIL oc got a write verb"; else echo "   ok   oc calls are read-only"; fi

echo "status tests: $((total-fails)) ok, $fails failed"; exit "$fails"
