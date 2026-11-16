#!/usr/bin/env bash
# Show how the hub's install is going, in one go (install guide, pages 3 and 4):
# deployment-root's sync and health and any error the root ApplicationSet apps
# reports, the Applications that aren't Synced and Healthy and those whose sync
# waits for its next retry, the MultiClusterHub's phase, Argo CD's application
# controller (restarts, and OOMKilled or CrashLoopBackOff called out), the
# tenant Keycloak's Application, and the provider console's Route; then, for each site in clusters.yaml, OpenShift
# AI's DataScienceCluster phase and its GridSite. Read-only; always exits 0
# once it reaches the hub.
#
# Runs against the hub in clusters.yaml, with its login (.config/NAME/kubeconfig).
#
# Usage: scripts/status.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
. "$here/gates.sh"
clusters_load "$here/.." || exit 1
hub=$(hub_name)
cluster_login_ok "$hub" || exit 1
KUBECONFIG=$(cluster_kubeconfig "$hub"); export KUBECONFIG
fix="see docs/install/troubleshooting.md, \"Nothing installs on the hub\""

echo "Hub $hub ($(oc whoami --show-server 2>/dev/null))"
# deployment-root syncs root/ (page 3); the root ApplicationSet apps reports
# a bad input or destination as an ErrorOccurred condition.
root=$(oc get applications.argoproj.io deployment-root -n openshift-gitops \
  -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
echo "deployment-root: ${root:-not created yet}"
oc get applicationsets.argoproj.io apps -n openshift-gitops -o json 2>/dev/null |
  jq -r '.status.conditions[]? | select(.type == "ErrorOccurred" and .status == "True") | .message' 2>/dev/null |
  while IFS= read -r msg; do echo "  !! The root ApplicationSet apps: $msg"; done

echo
# Applications that wait for the first site to join (page 6) are expected until
# then; scripts/gates.sh's app_rows marks them "site", by name or because their
# only unhealthy resources are ACM Placements that match no ManagedCluster yet.
appsjson=$(oc get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null || true)
apps=$(app_rows "$appsjson" "$(unmatched_placements)")
if [ -z "$apps" ]; then
  echo "Applications: none yet"
else
  n=$(wc -l <<<"$apps" | tr -d ' ')
  waiting="" problems=""
  while IFS=$'\t' read -r name sync health why; do
    [ "$sync $health" = "Synced Healthy" ] && continue
    if [ "$why" = site ]; then waiting+=" $name"
    else problems+=$(printf '  %-40s %-10s %s' "$name" "$sync" "$health")$'\n'; fi
  done <<<"$apps"
  if [ -z "$problems" ]; then
    if [ -z "$waiting" ]; then echo "Applications: all $n Synced and Healthy"
    else echo "Applications: none of $n has a problem"; fi
  else
    echo "Applications not Synced and Healthy ($(grep -c . <<<"$problems") of $n):"
    printf '%s' "$problems"
  fi
  [ -z "$waiting" ] || echo "Waiting for a site to join (expected until page 6):$waiting"
  # Syncs waiting for their next retry: a wait, not an error. The message's clock
  # time is UTC with no date, and not when the retry runs, so it isn't shown.
  jq -r '.items[] | select(.status.operationState.phase == "Running"
      and ((.status.operationState.message // "") | contains("Retrying attempt")))
    | [.metadata.name, ((.status.operationState.message | capture("Retrying attempt #(?<n>[0-9]+)").n)
      // (.status.operationState.retryCount // "?" | tostring))] | @tsv' <<<"$appsjson" 2>/dev/null |
    while IFS=$'\t' read -r name attempt; do
      case "$waiting " in *" $name "*) continue ;; esac
      echo "  $name: waiting for sync retry #$attempt (Argo CD retries with a backoff of up to 30 minutes)"
    done
fi

phase=$(oc get multiclusterhub -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
echo "MultiClusterHub: ${phase:-not created yet}"

# The controller is StatefulSet openshift-gitops-application-controller: pod -0.
pod=$(oc get pods -n openshift-gitops -o json 2>/dev/null |
  jq -r '[.items[] | select(.metadata.name | startswith("openshift-gitops-application-controller-"))][0] // empty
    | [.metadata.name,
      (.status.containerStatuses[0].restartCount // 0),
      (.status.containerStatuses[0].lastState.terminated.reason // "-"),
      (.status.containerStatuses[0].state.waiting.reason // "-")] | @tsv' 2>/dev/null)
if [ -z "$pod" ]; then
  echo "Argo CD controller: no pod yet"
else
  IFS=$'\t' read -r name restarts last waiting <<<"$pod"
  line="Argo CD controller: $name, $restarts restarts"
  [ "$last" = - ] || line+=", last termination $last"
  echo "$line"
  if [ "$last" = OOMKilled ] || [ "$waiting" = CrashLoopBackOff ]; then
    why=""; [ "$last" = - ] || why="last termination $last"
    [ "$waiting" = - ] || why+="${why:+, }now $waiting"
    echo "  !! The controller failed ($why); while it does, Applications don't progress: $fix."
  fi
fi

idp=$(oc get applications.argoproj.io tenant-idp -n openshift-gitops \
  -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
echo "tenant-idp: ${idp:-not created yet}"

host=$(oc get route ai-grid-provider-console -n ai-grid-provider-console -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "$host" ]; then echo "Console: https://$host"; else echo "Console: no Route yet"; fi

# Each site, through its own login: OpenShift AI's DataScienceCluster phase and
# the site's GridSite (Available or not).
for s in $(site_names); do
  echo
  if ! cluster_login_ok "$s" 2>/dev/null; then echo "Site $s: no working login (make login NAME=$s)"; continue; fi
  sk=$(cluster_kubeconfig "$s")
  echo "Site $s ($(cluster_field "$s" role))"
  dsc=$(KUBECONFIG=$sk oc get datasciencecluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  echo "  OpenShift AI (DataScienceCluster): ${dsc:-not created yet}"
  gs=$(KUBECONFIG=$sk oc get gridsites -A -o json 2>/dev/null |
    jq -r '.items[] | "\(.metadata.name) Available=\([.status.conditions[]? | select(.type == "Available") | .status][0] // "Unknown")"' 2>/dev/null)
  echo "  GridSite: ${gs:-not created yet}"
done
exit 0
