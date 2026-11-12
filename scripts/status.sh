#!/usr/bin/env bash
# Show how the hub's install is going, in one go (install guide, page 4): the
# Applications that aren't Synced and Healthy, the MultiClusterHub's phase,
# Argo CD's application controller (restarts, and OOMKilled or
# CrashLoopBackOff called out), the tenant Keycloak's Application, and the
# provider console's Route. Read-only; always exits 0 once it reaches the hub.
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
  echo "Argo CD controller: $name, $restarts restarts, last termination $last"
  if [ "$last" = OOMKilled ] || [ "$waiting" = CrashLoopBackOff ]; then
    echo "  !! The controller failed (last termination $last, now $waiting); while it does, Applications don't progress: $fix."
  fi
fi

idp=$(oc get applications.argoproj.io tenant-idp -n openshift-gitops \
  -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null)
echo "tenant-idp: ${idp:-not created yet}"

host=$(oc get route ai-grid-provider-console -n ai-grid-provider-console -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "$host" ]; then echo "Console: https://$host"; else echo "Console: no Route yet"; fi
exit 0
