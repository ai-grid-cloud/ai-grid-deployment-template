#!/usr/bin/env bash
# Runs the library's apps/console/create-secrets.sh at your pin against the hub
# from clusters.yaml (install guide, page 4). Takes the same environment
# variables; see that script.
#
# First it waits, printing progress, until the tenant Keycloak's Application
# tenant-idp is Synced and Healthy and the console's Route exists: up to
# CONSOLE_WAIT_SECONDS (default 1800), checking every CONSOLE_WAIT_INTERVAL
# seconds (default 20).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
library_dir "$here/.."
KUBECONFIG=$(cluster_kubeconfig "$hub"); export KUBECONFIG

timeout=${CONSOLE_WAIT_SECONDS:-1800} interval=${CONSOLE_WAIT_INTERVAL:-20} waited=0 last=""
while :; do
  idp=$(oc get applications.argoproj.io tenant-idp -n openshift-gitops \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || true)
  host=$(oc get route ai-grid-provider-console -n ai-grid-provider-console -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ "$idp" = "Synced Healthy" ] && [ -n "$host" ] && break
  now="tenant-idp: ${idp:-not created yet}; console Route: ${host:-not created yet}"
  if [ "$waited" -ge "$timeout" ]; then
    echo "error: not ready after $((timeout / 60)) minutes ($now). Run make status to see why." >&2
    exit 1
  fi
  [ "$now" = "$last" ] || echo "Waiting for the tenant Keycloak and the console: $now"
  last=$now
  sleep "$interval"; waited=$((waited + interval))
done
echo "tenant-idp is Synced and Healthy, and the console is at https://$host."
exec bash "$LIB/apps/console/create-secrets.sh" "$@"
