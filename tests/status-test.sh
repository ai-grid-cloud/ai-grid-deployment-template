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
  *" get applications.argoproj.io deployment-root "*) ans deployment-root ;;
  *" get applicationsets.argoproj.io apps "*) ans appset.json ;;
  *" get applications.argoproj.io "*) ans apps.json ;;
  *" get multiclusterhub "*) ans mch ;;
  *" get pods "*) ans pods.json ;;
  *" get placements."*) ans placements.json ;;
  *" get datasciencecluster "*) ans dsc ;;
  *" get gridsites "*) ans gridsites.json ;;
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
t "fresh: no deployment-root" "^deployment-root: not created yet$"

# Installing: some Applications not ready, and the controller OOMKilled.
W="$T/installing"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Progressing),$(app console Synced Healthy),$(app limitador-redis OutOfSync Degraded)]}" > "$W/apps.json"
printf 'Installing' > "$W/mch"
pods 3 OOMKilled CrashLoopBackOff > "$W/pods.json"
printf 'Synced Progressing' > "$W/tenant-idp"
t "lists the Applications not ready" "^  acm +Synced +Progressing$" "^  console "
t "counts them" "^Applications not Synced and Healthy \(1 of 3\):$"
t "the ones that wait for a site on one line" "^Waiting for a site to join \(expected until page 6\): limitador-redis$" "^  limitador-redis"
t "MultiClusterHub phase" "^MultiClusterHub: Installing$"
t "controller restarts and last termination" "^Argo CD controller: openshift-gitops-application-controller-0, 3 restarts, last termination OOMKilled$"
t "OOMKilled called out with the fix" "^  !! The controller failed .*OOMKilled.*troubleshooting"
t "tenant-idp state" "^tenant-idp: Synced Progressing$"
pods 2 Error CrashLoopBackOff > "$W/pods.json"
t "CrashLoopBackOff called out" "^  !! The controller failed .*CrashLoopBackOff"
printf 'OutOfSync Healthy' > "$W/deployment-root"
t "deployment-root's state" "^deployment-root: OutOfSync Healthy$"
total=$((total+1))
if [ "$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/status.sh" 2>&1 | sed -n 2p)" = "deployment-root: OutOfSync Healthy" ]
then echo "   ok     ... right under the hub's name"; else fails=$((fails+1)); echo "   FAIL   ... right under the hub's name"; fi
cat > "$W/appset.json" <<'JSON'
{"status":{"conditions":[{"type":"ParametersGenerated","status":"True","message":"ok"},
 {"type":"ErrorOccurred","status":"True","message":"missing input: catalogRepoURL"},
 {"type":"ResourcesUpToDate","status":"False","message":"other"}]}}
JSON
t "the root ApplicationSet's error called out" "^  !! The root ApplicationSet apps: missing input: catalogRepoURL$"
t "  ... and only that condition" "!! The root ApplicationSet" "other|ParametersGenerated"

# Applications Degraded only by Placements that match no ManagedCluster wait
# for a site; one with another unhealthy resource, or an unrelated Placement,
# is a problem.
W="$T/placements"; mkdir -p "$W"
res() { # kind namespace name [health]
  local h=""; [ -z "${4:-}" ] || h=",\"health\":{\"status\":\"$4\"}"
  printf '{"kind":"%s","namespace":"%s","name":"%s"%s}' "$1" "$2" "$3" "$h"
}
appr() { printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s"},"health":{"status":"%s"},"resources":[%s]}}' "$@"; }
echo "{\"items\":[$(appr models Synced Degraded "$(res Placement acm-models models-site)"),$(appr spokes Synced Degraded "$(res Placement ai-grid-spokes p1 Degraded),$(res Deployment ai-grid-spokes d1 Healthy)"),$(appr broken Synced Degraded "$(res Placement ai-grid-spokes p1 Degraded),$(res Deployment x d2 Degraded)"),$(appr other Synced Degraded "$(res Placement x matched)")]}" > "$W/apps.json"
cat > "$W/placements.json" <<'JSON'
{"items":[
 {"metadata":{"namespace":"acm-models","name":"models-site"},"status":{"conditions":[{"type":"PlacementSatisfied","status":"False","reason":"NoManagedClusterMatched","message":"No ManagedCluster matches any of the cluster predicate"}]}},
 {"metadata":{"namespace":"ai-grid-spokes","name":"p1"},"status":{"conditions":[{"type":"PlacementSatisfied","status":"False","reason":"NoManagedClusterMatched","message":"No ManagedCluster matches any of the cluster predicate"}]}},
 {"metadata":{"namespace":"x","name":"matched"},"status":{"conditions":[{"type":"PlacementSatisfied","status":"True","message":"Placement pending"}]}}]}
JSON
t "placement-only Applications wait for a site" "^Waiting for a site to join \(expected until page 6\): models spokes$"
t "another unhealthy resource is a problem" "^  broken +Synced +Degraded$"
t "a Placement that matches is a problem" "^  other +Synced +Degraded$"
rm "$W/placements.json"
t "no Placements readable: nothing waits" "^  models +Synced +Degraded$"

# A sync that keeps retrying because its only failed tasks are Placements
# that match no ManagedCluster also waits for a site; any other failed task
# is a problem. Placements aren't readable here: the failed tasks say enough.
W="$T/retrying"; mkdir -p "$W"
appop() { # name sync health task-json...
  local n=$1 sy=$2 h=$3; shift 3; local IFS=,
  printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s"},"health":{"status":"%s"},"operationState":{"phase":"Running","message":"one or more synchronization tasks completed unsuccessfully. Retrying attempt #3 at 6:49PM","syncResult":{"resources":[%s]}}}}' "$n" "$sy" "$h" "$*"
}
task() { # group kind name status hookPhase message, as Argo CD records a sync task
  printf '{"group":"%s","kind":"%s","namespace":"x","name":"%s","status":"%s","hookPhase":"%s","message":"%s"}' "$@"; }
nomatch="No ManagedCluster matches any of the cluster predicate"
pl=cluster.open-cluster-management.io
echo "{\"items\":[$(appop rhoai OutOfSync Degraded "$(task $pl Placement p1 Synced Failed "$nomatch")" \
  "$(task $pl Placement p2 Synced Succeeded "placement created")" "$(task apps Deployment d1 Synced Succeeded ok)"),$(appop \
  odd OutOfSync Degraded "$(task $pl Placement p1 Synced Failed "$nomatch")" "$(task apps Deployment d2 SyncFailed Failed boom)")]}" \
  > "$W/apps.json"
t "a sync retrying only on no-match Placements waits for a site" "^Waiting for a site to join \(expected until page 6\): rhoai$" "^  rhoai "
t "  ... another failed task is a problem" "^  odd +OutOfSync +Degraded$"
t "a sync retry is named, with its attempt" "^  odd: waiting for sync retry #3 \(Argo CD retries with a backoff of up to 30 minutes\)$"
t "  ... once, not for an Application already waiting for a site" "^  odd: waiting" "rhoai: waiting"
t "  ... without the message's clock time" "^  odd: waiting" "PM|AM"

# Done: everything ready, the controller healthy, the console up.
W="$T/done"; mkdir -p "$W"
echo "{\"items\":[$(app acm Synced Healthy),$(app tenant-idp Synced Healthy)]}" > "$W/apps.json"
printf 'Running' > "$W/mch"; pods 0 > "$W/pods.json"; printf 'Synced Healthy' > "$W/tenant-idp"
printf 'console.apps.hub.example.com' > "$W/route"; printf 'Synced Healthy' > "$W/deployment-root"
echo '{"status":{"conditions":[{"type":"ErrorOccurred","status":"False","message":"Successfully generated parameters"}]}}' > "$W/appset.json"
t "done: deployment-root Synced" "^deployment-root: Synced Healthy$"
t "done: all Applications ready" "^Applications: all 2 Synced and Healthy$"
t "done: no warning, no empty termination" "^Argo CD controller: openshift-gitops-application-controller-0, 0 restarts$" "!!"
t "done: console URL" "^Console: https://console.apps.hub.example.com$"
# Sites: each one's DataScienceCluster phase and GridSite, through its login.
D="$T/repo-sites"; mkdir -p "$D/.config/hub" "$D/.config/site-b"; cp -R "$SRC/scripts" "$D/"
: > "$D/.config/hub/kubeconfig"; : > "$D/.config/site-b/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n  - {name: site-c, role: inference, location: us-west, api: "https://api.site-c.example.com:6443"}\n' > "$D/clusters.yaml"
W="$T/sites"; mkdir -p "$W"
t "site not installed yet" "^  OpenShift AI \(DataScienceCluster\): not created yet$"
t "  ... no GridSite yet" "^  GridSite: not created yet$"
t "a site without a login" "^Site site-c: no working login \(make login NAME=site-c\)$"
printf 'Ready' > "$W/dsc"
echo '{"items":[{"metadata":{"name":"site-b"},"status":{"conditions":[{"type":"Available","status":"True"}]}}]}' > "$W/gridsites.json"
t "site ready" "^  OpenShift AI \(DataScienceCluster\): Ready$"
t "  ... GridSite available" "^  GridSite: site-b Available=True$"
t "  ... named with its role" "^Site site-b \(combined\)$"

total=$((total+1))
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale|rollout' "$T"/*/argv.log; then
  fails=$((fails+1)); echo "   FAIL oc got a write verb"; else echo "   ok   oc calls are read-only"; fi

echo "status tests: $((total-fails)) ok, $fails failed"; exit "$fails"
