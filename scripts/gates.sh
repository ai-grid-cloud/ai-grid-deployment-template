#!/usr/bin/env bash
# Readiness gates for the install: wait for a named condition, then go on.
# Sourced, never run. Every check is read-only. Each runs against the cluster
# in the caller's KUBECONFIG (the hub, or a site).
#
#   gate NAME TIMEOUT_SECONDS CHECK [ARG...]
#       runs CHECK ARG... every GATE_INTERVAL seconds (default 15) until it
#       exits 0 or TIMEOUT_SECONDS pass. Prints "gate NAME: waiting (REASON)"
#       at most once a minute, REASON being the check's last line of output,
#       and "gate NAME: passed after Ns". On passing it removes
#       .install/failed-gate, so a passing rerun leaves no stale gate for
#       scripts/install-report.sh. On timeout, or after GATE_ERROR_LIMIT
#       consecutive oc errors (default 4), prints
#       "gate NAME: FAILED after Ns: REASON", writes NAME to
#       .install/failed-gate, and returns 1. .install/ is in the deployment
#       repository that clusters_load read (scripts/clusters.sh), or in the
#       current directory when none was loaded.
#
# Checks: each prints one reason line and returns 0 when ready, 1 when not
# ready, and 2 when an oc call failed (an expired login, say): the reason is
# then "oc error: " and the last line of oc's stderr. A missing object, or a
# resource type the cluster doesn't have yet, is not ready, not an error.
#   app_healthy NAME             Argo CD Application NAME is Synced and Healthy
#   apps_healthy [--strict] [EXCEPT...]
#                                every Application is Synced and Healthy, except
#                                the names given and those waiting for a site;
#                                with --strict, those waiting for a site count
#                                as not ready
#   root_synced_to REV           Application deployment-root is Synced at REV,
#                                a full commit SHA (Argo CD reports full SHAs)
#   mch_running                  the MultiClusterHub's phase is Running
#   managedcluster_available NAME  ManagedCluster NAME is joined and available
#   route_answers NAMESPACE NAME [CODES]  https on the Route's host answers one
#                                of CODES (default 200 302 401 403), with the
#                                system's CA trust; with no answer, the reason
#                                is curl's error
#
# Also used by scripts/status.sh, so the two agree on what waits for a site:
#   waits_for_site_names         the Applications that wait for a site by name
#   unmatched_placements         Placements that match no ManagedCluster, as a
#                                JSON array of "namespace/name"
#   app_rows APPS_JSON UNMATCHED one row per Application: name, sync, health,
#                                and "site" when it waits for a site, else "-"
#
# Time limits, in seconds, each overridable from the environment (install.env):
: "${GATE_INTERVAL:=15}"
: "${GATE_ERROR_LIMIT:=4}"            # consecutive oc errors before a gate fails
: "${GATE_ROOT_SECONDS:=600}"         # deployment-root Synced
: "${GATE_MCH_SECONDS:=1800}"         # MultiClusterHub Running
: "${GATE_HUB_APPS_SECONDS:=3600}"    # every hub Application
: "${GATE_O11Y_SECONDS:=2700}"        # ODF and the o11y Applications
: "${GATE_TENANT_IDP_SECONDS:=1800}"  # tenant-idp
: "${GATE_SITE_IMPORT_SECONDS:=900}"  # a site's import
: "${GATE_READY_SECONDS:=600}"        # the ready check (make install's last gate)

gate() { # NAME TIMEOUT_SECONDS CHECK [ARG...]
  local name=$1 timeout=$2; shift 2
  local start=$SECONDS elapsed out rc reason="" shown=-60 errors=0
  local dir="${CLUSTERS_DIR:-$PWD}/.install"
  while :; do
    out=$("$@") && rc=0 || rc=$?
    if [ "$rc" = 0 ]; then
      rm -f "$dir/failed-gate"
      echo "gate $name: passed after $((SECONDS - start))s"; return 0
    fi
    [ "$rc" = 2 ] && errors=$((errors + 1)) || errors=0
    reason=$(grep . <<<"$out" | tail -n 1 || true)
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ] || [ "$errors" -ge "$GATE_ERROR_LIMIT" ]; then
      echo "gate $name: FAILED after ${elapsed}s: ${reason:-no reason given}"
      mkdir -p "$dir" && echo "$name" > "$dir/failed-gate"
      return 1
    fi
    if [ $((elapsed - shown)) -ge 60 ]; then
      echo "gate $name: waiting (${reason:-no reason given})"; shown=$elapsed
    fi
    sleep "$GATE_INTERVAL"
  done
}

# Applications that wait for the first site to join (install guide, page 6),
# expected until then: these three by name, and any whose only unhealthy
# resources are ACM Placements that match no ManagedCluster yet.
waits_for_site_names() { echo "acm-submariner-local-cluster limitador-redis maas-db-local-cluster"; }

unmatched_placements() {
  oc get placements.cluster.open-cluster-management.io -A -o json 2>/dev/null |
    jq -c '[.items[] | select(any(.status.conditions[]?; .type == "PlacementSatisfied" and .status == "False"
        and ((.message // "") | contains("No ManagedCluster matches any of the cluster predicate"))))
      | "\(.metadata.namespace)/\(.metadata.name)"]' 2>/dev/null
}

# One row per Application: name, sync, health, and "site" when it's one of
# waits_for_site_names, or it's Synced and what keeps it from Healthy is a
# Placement that matches no ManagedCluster: it has one, and every resource whose
# health Argo CD reports as not Healthy is one. Also "site" when its sync keeps
# retrying because every failed task is such a Placement, so the later waves wait.
# Argo CD may not keep each resource's health in the Application, so the
# Placements themselves are read (UNMATCHED, from unmatched_placements).
app_rows() { # APPS_JSON UNMATCHED
  jq -r --argjson u "${2:-[]}" --arg names " $(waits_for_site_names) " '.items[] | [.metadata.name, (.status.sync.status // "Unknown"),
      (.status.health.status // "Unknown"),
      ([.status.resources[]? | select(.kind == "Placement") | "\(.namespace)/\(.name)" | select(IN($u[]))] as $waiting
       | [.status.resources[]? | select(.health != null and .health.status != "Healthy")
          | select((.kind == "Placement" and ("\(.namespace)/\(.name)" | IN($u[]))) | not)] as $other
       | [.status.operationState.syncResult.resources[]? | select(.hookPhase == "Failed" or .status == "SyncFailed")] as $failed
       | .metadata.name as $n | if ($names | contains(" \($n) ")) then "site"
         elif .status.sync.status == "Synced" and ($waiting | length > 0) and ($other | length == 0)
         then "site"
         elif ($failed | length > 0) and all($failed[]; .kind == "Placement"
           and ((.message // "") | contains("No ManagedCluster matches")))
         then "site" else "-" end)] | @tsv' <<<"$1" 2>/dev/null
}

# oc_read ARG...: runs oc ARG... and prints its output. When oc fails it
# returns 1 with no output if the object or its resource type doesn't exist,
# and otherwise prints "oc error: " and the last line of oc's stderr and
# returns 2. Tokens never travel in argv, so that stderr holds no secret.
oc_read() {
  local out err rc
  err=$(mktemp)
  out=$(oc "$@" 2>"$err") && rc=0 || rc=$?
  if [ "$rc" != 0 ]; then
    if grep -qE 'NotFound|the server doesn.t have a resource type' "$err"; then rc=1
    else echo "oc error: $(grep . "$err" | tail -n 1)"; rc=2; fi
    rm -f "$err"; return "$rc"
  fi
  rm -f "$err"; printf '%s\n' "$out"
}

app_healthy() { # NAME
  local json s
  json=$(oc_read get applications.argoproj.io "$1" -n openshift-gitops -o json) ||
    { [ $? = 2 ] && { echo "$json"; return 2; }; echo "Application $1: not created yet"; return 1; }
  s=$(jq -r '"\(.status.sync.status // "Unknown") \(.status.health.status // "Unknown")"' <<<"$json" 2>/dev/null)
  [ -n "$s" ] || { echo "Application $1: not created yet"; return 1; }
  [ "$s" = "Synced Healthy" ] || { echo "Application $1: $s"; return 1; }
}

apps_healthy() { # [--strict] [EXCEPT...]
  local json rows name sync health why bad="" n=0 strict=""
  [ "${1:-}" != --strict ] || { strict=1; shift; }
  json=$(oc_read get applications.argoproj.io -n openshift-gitops -o json) ||
    { [ $? = 2 ] && { echo "$json"; return 2; }; echo "Applications: can't read them"; return 1; }
  rows=$(app_rows "$json" "$(unmatched_placements || true)" || true)
  [ -n "$rows" ] || { echo "Applications: none yet"; return 1; }
  while IFS=$'\t' read -r name sync health why; do
    [ "$sync $health" = "Synced Healthy" ] && continue
    [ "$why" = site ] && [ -z "$strict" ] && continue
    case " $* " in *" $name "*) continue ;; esac
    n=$((n + 1)); bad+="${bad:+, }$name ($sync $health)"
  done <<<"$rows"
  [ -z "$bad" ] || { echo "$n Application(s) not Synced and Healthy: $bad"; return 1; }
}

# REV must be a full commit SHA: it's compared as a string with the
# revisions Argo CD reports, which are full SHAs, so a short SHA never matches.
root_synced_to() { # REV
  local json s
  json=$(oc_read get applications.argoproj.io deployment-root -n openshift-gitops -o json) ||
    { [ $? = 2 ] && { echo "$json"; return 2; }; echo "Application deployment-root: not created yet"; return 1; }
  s=$(jq -r --arg r "$1" '(.status.sync.status // "Unknown") as $s
      | ([.status.sync.revision // empty, (.status.sync.revisions[]? // empty)]) as $revs
      | if $s == "Synced" and ($revs | index($r)) then "ok"
        else "\($s) at \(($revs | join(",")) | if . == "" then "no revision" else . end)" end' <<<"$json" 2>/dev/null)
  [ -n "$s" ] || { echo "Application deployment-root: not created yet"; return 1; }
  [ "$s" = ok ] || { echo "Application deployment-root: $s, not Synced at $1"; return 1; }
}

mch_running() {
  local json p=""
  json=$(oc_read get multiclusterhub -A -o json) || { [ $? = 2 ] && { echo "$json"; return 2; }; }
  [ -z "$json" ] || p=$(jq -r '.items[0].status.phase // empty' <<<"$json" 2>/dev/null)
  [ "$p" = Running ] || { echo "MultiClusterHub: ${p:-not created yet}"; return 1; }
}

managedcluster_available() { # NAME
  local json c s
  json=$(oc_read get managedclusters.cluster.open-cluster-management.io "$1" -o json) ||
    { [ $? = 2 ] && { echo "$json"; return 2; }; echo "ManagedCluster $1: not created yet"; return 1; }
  for c in ManagedClusterJoined ManagedClusterConditionAvailable; do
    s=$(jq -r --arg c "$c" '[.status.conditions[]? | select(.type == $c) | .status][0] // "Unknown"' <<<"$json" 2>/dev/null)
    [ "$s" = True ] || { echo "ManagedCluster $1: $c is ${s:-Unknown}"; return 1; }
  done
}

route_answers() { # NAMESPACE NAME [CODES]
  local ns=$1 name=$2 json host="" code codes err why; shift 2
  codes=" ${*:-200 302 401 403} "
  json=$(oc_read get route "$name" -n "$ns" -o json) || { [ $? = 2 ] && { echo "$json"; return 2; }; }
  [ -z "$json" ] || host=$(jq -r '.spec.host // empty' <<<"$json" 2>/dev/null)
  [ -n "$host" ] || { echo "Route $ns/$name: not created yet"; return 1; }
  err=$(mktemp)
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://$host/" 2>"$err") || true
  why=$(grep . "$err" | tail -n 1 || true); rm -f "$err"
  case "$codes" in *" ${code:-000} "*) return 0 ;; esac
  if [ -n "$why" ]; then echo "Route $ns/$name: https://$host/ answered ${code:-000}: $why"
  else echo "Route $ns/$name: https://$host/ answered ${code:-000}, not one of${codes% }"; fi
  return 1
}
