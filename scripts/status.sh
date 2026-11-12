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
# These wait for the first site to join (page 6), so they're expected until then.
waits_for_site=" acm-submariner-local-cluster limitador-redis maas-db-local-cluster "
fix="see docs/install/troubleshooting.md, \"Nothing installs on the hub\""

echo "Hub $hub ($(oc whoami --show-server 2>/dev/null))"

echo
apps=$(oc get applications.argoproj.io -n openshift-gitops -o json 2>/dev/null |
  jq -r '.items[] | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")] | @tsv' 2>/dev/null)
if [ -z "$apps" ]; then
  echo "Applications: none yet"
else
  n=$(wc -l <<<"$apps" | tr -d ' ')
  not_ok=$(awk -F'\t' '!($2 == "Synced" && $3 == "Healthy")' <<<"$apps")
  if [ -z "$not_ok" ]; then
    echo "Applications: all $n Synced and Healthy"
  else
    echo "Applications not Synced and Healthy ($(wc -l <<<"$not_ok" | tr -d ' ') of $n):"
    while IFS=$'\t' read -r name sync health; do
      note=""; case "$waits_for_site" in *" $name "*) note="  (waits for a site; expected until page 6)" ;; esac
      printf '  %-40s %-10s %s%s\n' "$name" "$sync" "$health" "$note"
    done <<<"$not_ok"
  fi
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
