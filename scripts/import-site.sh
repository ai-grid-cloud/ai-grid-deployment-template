#!/usr/bin/env bash
# Import a site from clusters.yaml into the hub's ACM, with the library's
# import script at your pin (docs/acm/cluster-onboarding/import-managed-cluster.sh).
# A preview by default: it prints the library script's summary and changes
# nothing. With --yes (make site-import CONFIRM=1) it imports. A site already
# joined and available on the hub is left alone.
#
#   scripts/import-site.sh [NAME] [--yes] [other flags of the library script]
#
# NAME defaults to the only site in clusters.yaml.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
. "$here/clusters.sh"
clusters_load "$here/.."
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then name=$(site_name "$1"); shift; else name=$(site_name); fi
[ "$(cluster_field "$name" role)" != hub ] || { echo "error: $name is the hub" >&2; exit 1; }
hub=$(hub_name)
cluster_login_ok "$hub"; cluster_login_ok "$name"
# Already joined and available on this hub: nothing for the import to do.
state=$(KUBECONFIG=$(cluster_kubeconfig "$hub") oc get managedcluster "$name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status} {.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)
if [ "$state" = "True True" ]; then echo "$name is already imported; nothing to do."; exit 0; fi
library_dir "$here/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
merge_kubeconfigs "$hub" "$name" "$tmp/kubeconfig"
run_import() {
  KUBECONFIG="$tmp/kubeconfig" bash "$LIB/docs/acm/cluster-onboarding/import-managed-cluster.sh" \
    --hub-context hub --spoke-context site --cluster-name "$name" "$@"
}
case " $* " in *" --yes "*) run_import "$@"; exit ;; esac
run_import "$@" | sed 's/^No changes were made\. Rerun with --yes to import the cluster\.$/No changes were made. To import, run: make site-import CONFIRM=1/'
