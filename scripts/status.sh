#!/usr/bin/env bash
# Show how the hub's install is going, in one go (install guide, pages 3 and 4):
# deployment-root's sync and health and any error the root ApplicationSet apps
# reports, the Applications that aren't Synced and Healthy, the
# MultiClusterHub's phase, Argo CD's application controller (restarts, and
# OOMKilled or CrashLoopBackOff called out), the tenant Keycloak's Application, and the
# provider console's Route; then, for each site in clusters.yaml, OpenShift
# AI's DataScienceCluster phase and its GridSite. Read-only; always exits 0
# once it reaches the hub.
#
# Runs against the hub in clusters.yaml, with its login (.config/NAME/kubeconfig).
#
# Usage: scripts/status.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.." || exit 1
hub=$(hub_name)
cluster_login_ok "$hub" || exit 1
KUBECONFIG=$(cluster_kubeconfig "$hub"); export KUBECONFIG
# Applications that wait for the first site to join (page 6), expected until
# then: these three by name, and any whose only unhealthy resources are ACM
# Placements that match no ManagedCluster yet.
waits_for_site=" acm-submariner-local-cluster limitador-redis maas-db-local-cluster "
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
# Placements that match no ManagedCluster yet, as "namespace/name". Argo CD may not
# keep each resource's health in the Application, so read the Placements themselves.
unmatched=$(oc get placements.cluster.open-cluster-management.io -A -o json 2>/dev/null |
  jq -c '[.items[] | select(any(.status.conditions[]?; .type == "PlacementSatisfied" and .status == "False"
      and ((.message // "") | contains("No ManagedCluster matches any of the cluster predicate"))))
    | "\(.metadata.namespace)/\(.metadata.name)"]' 2>/dev/null)
# One row per Application: name, sync, health, and "site" when it's Synced and
# what keeps it from Healthy is such a Placement: it has one, and every resource
# whose health Argo CD reports as not Healthy is one.
apps=$(oc get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null |
  jq -r --argjson u "${unmatched:-[]}" '.items[] | [.metadata.name, (.status.sync.status // "Unknown"),
      (.status.health.status // "Unknown"),
      ([.status.resources[]? | select(.kind == "Placement") | "\(.namespace)/\(.name)" | select(IN($u[]))] as $waiting
       | [.status.resources[]? | select(.health != null and .health.status != "Healthy")
          | select((.kind == "Placement" and ("\(.namespace)/\(.name)" | IN($u[]))) | not)] as $other
       | if .status.sync.status == "Synced" and ($waiting | length > 0) and ($other | length == 0)
         then "site" else "-" end)] | @tsv' 2>/dev/null)
if [ -z "$apps" ]; then
  echo "Applications: none yet"
else
  n=$(wc -l <<<"$apps" | tr -d ' ')
  waiting="" problems=""
  while IFS=$'\t' read -r name sync health why; do
    [ "$sync $health" = "Synced Healthy" ] && continue
    case "$waits_for_site" in *" $name "*) why=site ;; esac
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
