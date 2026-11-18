#!/usr/bin/env bash
# Detach a site from its old ACM hub on the site itself, for when that hub is
# gone or you can't sign in to it (install guide, page 5; make site-detach).
# When the old hub still answers, detach the site there instead: the hub then
# also removes its add-ons, such as Submariner, cleanly.
#
# Deletes the ACM Klusterlet (klusterlet) and waits until the klusterlet
# operator has removed the agent namespaces open-cluster-management-agent and
# open-cluster-management-agent-addon. This is what "clusteradm unjoin" does
# first; the operator itself, and Submariner, stay for wipe-site.sh. With no
# Klusterlet left, it deletes the agent namespaces itself.
#
# Then it deletes the old hub's AppliedManifestWorks, the work agent's records of
# what each of that hub's ManifestWorks applied. They outlive the agent, and after
# an import into a new hub they co-own the same objects as the new hub's works:
# deleting an add-on on the new hub then uninstalls nothing, and the old add-on
# state, such as Submariner's broker and Globalnet range, stays (site-c,
# 2026-11-18). Their finalizer is the work agent's, which is gone, so it's
# dropped; the objects they applied stay for wipe-site.sh.
#
#   scripts/detach-site.sh [--site NAME | --kubeconfig PATH] [--dry-run] [--timeout SECONDS]
#
# Refuses on an ACM hub, and on a site that is a ManagedCluster of your own hub
# (uninstall it with make uninstall-site instead).
set -Eeuo pipefail
AGENT_NAMESPACES="open-cluster-management-agent open-cluster-management-agent-addon"
KLUSTERLET=klusterlets.operator.open-cluster-management.io
AMW=appliedmanifestworks.work.open-cluster-management.io

usage() { echo "Usage: detach-site.sh [--site NAME | --kubeconfig PATH] [--dry-run] [--timeout SECONDS]  (default: the only site's login)"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kubeconfig="" name="" dry_run=false timeout="${DETACH_TIMEOUT:-600}"
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig|--site|--timeout) [ $# -ge 2 ] || { usage >&2; die "$1 needs a value"; } ;;
  esac
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --site) name="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) die "--timeout takes a number of seconds" ;; esac
site=""
if [ -z "$kubeconfig" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  . "$here/clusters.sh"
  clusters_load "$here/.." || exit 1
  site=$(site_name "$name") || exit 1
  cluster_login_ok "$site" || exit 1
  kubeconfig=$(cluster_kubeconfig "$site")
fi
k() { oc --kubeconfig "$kubeconfig" "$@"; }

k get managedcluster >/dev/null 2>&1 && die "this cluster is an ACM hub; detach-site.sh is for sites"
# Your own hub's site: detaching it here would leave the hub's ManagedCluster,
# add-ons and Argo CD cluster Secret behind.
if [ -n "$site" ]; then
  hub=$(hub_name)
  cluster_login_ok "$hub" >/dev/null 2>&1 || die "can't check whether your hub $hub manages $site: run make login NAME=$hub"
  if oc --kubeconfig "$(cluster_kubeconfig "$hub")" get managedcluster "$site" >/dev/null 2>&1; then
    die "$site is a ManagedCluster on your hub $hub: uninstall it with make uninstall-site (page 8), or delete that ManagedCluster first"
  fi
else
  echo "warning: with --kubeconfig, this doesn't check that your own hub doesn't manage this cluster" >&2
fi

has_klusterlet() { k get "$KLUSTERLET" klusterlet -o name >/dev/null 2>&1; }
agent_left() { local ns; for ns in $AGENT_NAMESPACES; do k get ns "$ns" -o name >/dev/null 2>&1 && echo "namespace $ns"; done; true; }

amws() { k get "$AMW" -o name 2>/dev/null || true; }
drop_amws() { # the old hub's AppliedManifestWorks, without the work agent's finalizer
  local a
  for a in $(amws); do
    if $dry_run; then echo "would delete without finalizers: $a"; continue; fi
    k patch "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    k delete "$a" --ignore-not-found --wait=false
  done
}

left="$(agent_left)"
if ! has_klusterlet && [ -z "$left" ]; then
  if [ -n "$(amws)" ]; then
    drop_amws
    echo "== done$($dry_run && echo ' (dry run: nothing deleted)')"
    exit 0
  fi
  echo "No Klusterlet, ACM agent namespaces or AppliedManifestWorks: the site isn't managed by any hub. Nothing to do."
  exit 0
fi

if has_klusterlet; then
  if $dry_run; then echo "would delete: $KLUSTERLET klusterlet (the klusterlet operator then removes the agent)"
  else k delete "$KLUSTERLET" klusterlet --ignore-not-found --wait=false; fi
else
  # No Klusterlet, so no operator will clean up: delete what's left directly.
  for ns in $AGENT_NAMESPACES; do
    k get ns "$ns" -o name >/dev/null 2>&1 || continue
    if $dry_run; then echo "would delete: ns $ns"; else k delete ns "$ns" --ignore-not-found --wait=false; fi
  done
fi
if $dry_run; then
  echo "would wait up to ${timeout}s for the Klusterlet and the namespaces $AGENT_NAMESPACES to go"
  drop_amws
  echo "== done (dry run: nothing deleted)"
  exit 0
fi

poll="${DETACH_POLL:-10}" start=$SECONDS
while :; do
  left="$(has_klusterlet && echo "Klusterlet klusterlet"; agent_left)"
  [ -z "$left" ] && break
  if [ $((SECONDS - start)) -ge "$timeout" ]; then
    die "still present after ${timeout}s: $(echo $left | sed 's/ namespace/, namespace/g').
  The klusterlet operator (Deployment klusterlet in open-cluster-management) removes them; check that its pod runs:
  oc get pods -n open-cluster-management. Then run this again."
  fi
  sleep "$poll"
done
drop_amws
echo "Detached: the Klusterlet, the ACM agent namespaces and the old hub's AppliedManifestWorks are gone. Next: make site-wipe (page 5)."
