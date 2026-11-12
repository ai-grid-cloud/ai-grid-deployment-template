#!/usr/bin/env bash
# Uninstall AI Grid: each site, then the hub. The end state is each cluster as
# it was before the install (docs/install/08-uninstall.md).
#
#   scripts/uninstall.sh site [NAME] [--dry-run] [--plan-file PATH]
#   scripts/uninstall.sh hub       [--dry-run] [--plan-file PATH]
#
# NAME is a site in clusters.yaml (its ACM ManagedCluster name); it defaults to
# the only site. Each
# cluster's login is .config/NAME/kubeconfig (make login NAME=...); the site
# step uses the hub's login and the site's.
#
# --dry-run prints every step and every object it would delete, in order, and
# deletes nothing. The object list comes from Argo CD's own inventory
# (uninstall-plan.py); operators then remove what they created.
#
# --plan-file saves the plan on the first run and reuses it on a rerun. The plan
# comes from Argo CD's Applications, which the first run removes, so a step that
# stops partway can only resume with its plan file.
#
# Safety:
# - Refuses a login whose API server isn't the cluster's api in clusters.yaml.
# - Refuses unless each login is cluster-admin, and unless that access comes
#   through a binding the uninstall doesn't delete.
# - Never touches the protected namespaces and operator packages (the
#   platform's Keycloak, cert-manager, NFD, GPU operator, openshift-config,
#   openshift-authentication), ClusterIssuers, OAuth, the cluster pull secret
#   or image mirror, or CRDs. Extend the protected lists with
#   WIPE_PROTECT_NAMESPACES and WIPE_PROTECT_PACKAGES (space-separated), for
#   example with the namespace of the identity provider you sign in with.
# - The hub step refuses while any site is still managed.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

step="${1:-}"; [ $# -eq 0 ] || shift
site="" plan_file="" dry_run=false
case "$step" in
  site) if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then site=$1; shift; fi ;;
  hub) ;;
  -h|--help) usage; exit 0 ;;
  *) die "usage: uninstall.sh site [NAME] | hub [--dry-run] [--plan-file PATH] (see --help)" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --plan-file) [ $# -ge 2 ] || die "--plan-file needs a path"; plan_file=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
for c in oc python3; do command -v "$c" >/dev/null || die "required command not found: $c"; done

clusters_load "$here/.."
hub=$(hub_name)
if [ "$step" = site ]; then
  [ "$site" != local-cluster ] || die "a hub that is also a site isn't supported yet: unlabel local-cluster, then run the hub step"
  [ "$site" != "$hub" ] || die "$site is the hub: run uninstall.sh hub"
  site=$(site_name "$site") || exit 1
fi

protect_ns="${WIPE_PROTECT_NAMESPACES:-}" protect_pkgs="${WIPE_PROTECT_PACKAGES:-}"
hub_kc=$(cluster_kubeconfig "$hub"); site_kc=""
[ "$step" = hub ] || site_kc=$(cluster_kubeconfig "$site")
H() { oc --kubeconfig "$hub_kc" "$@"; }
S() { oc --kubeconfig "$site_kc" "$@"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- checks ---------------------------------------------------------------
check_api() { # NAME: the login's API server is the cluster's api in clusters.yaml
  local want got
  want=$(cluster_field "$1" api | sed 's#/*$##')
  got=$(oc --kubeconfig "$(cluster_kubeconfig "$1")" whoami --show-server 2>/dev/null | sed 's#/*$##')
  [ "$got" = "$want" ] || die "$1: the login is for ${got:-no server}, not $want (clusters.yaml); run make login NAME=$1"
}
check_admin() { # KUBECONFIG LABEL: the login works and is cluster-admin
  local kc=$1 label=$2 who
  who=$(oc --kubeconfig "$kc" whoami 2>/dev/null) || die "$label: login expired: run make login NAME=$label"
  [ "$(oc --kubeconfig "$kc" auth can-i '*' '*' --all-namespaces 2>/dev/null)" = yes ] ||
    die "$label: $who isn't cluster-admin; sign in as a cluster-admin (make login NAME=$label)"
  echo "$label: signed in as $who, cluster-admin."
}
warn_idp() { # KUBECONFIG LABEL: the uninstall must not remove the identity provider the sign-in depends on
  local idps
  idps=$(oc --kubeconfig "$1" get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)
  echo "warning: $2 signs in through: ${idps:-no identity providers}. The uninstall never edits OAuth, but it deletes"
  echo "  whatever isn't protected. If a provider's server runs on this cluster outside the protected namespaces,"
  echo "  add its namespace to WIPE_PROTECT_NAMESPACES (and its operator to WIPE_PROTECT_PACKAGES) first."
}
login_binding_kept() { # KUBECONFIG LABEL PLANFILE: the login's cluster-admin doesn't come only from objects the plan deletes
  local kc=$1 who groups lost
  who=$(oc --kubeconfig "$kc" whoami 2>/dev/null)
  groups=$(oc --kubeconfig "$kc" auth whoami -o jsonpath='{.status.userInfo.groups[*]}' 2>/dev/null || true)
  # Prints the planned bindings or Groups the login's cluster-admin depends on, but
  # only when no binding outside the plan grants it.
  lost="$(oc --kubeconfig "$kc" get clusterrolebindings -o json | python3 -c '
import json, sys
user, groups = sys.argv[1], set(sys.argv[2].split())
plan = [l.rstrip("\n").split("\t") for l in open(sys.argv[3]) if l.strip()]
planned_crbs = {p[3] for p in plan if len(p) == 4 and p[1].startswith("ClusterRoleBinding")}
planned_groups = {p[3] for p in plan if len(p) == 4 and p[1].split(".")[0] == "Group"}
kept, lost = [], []
for b in json.load(sys.stdin)["items"]:
    name = b["metadata"]["name"]
    if b["roleRef"]["name"] != "cluster-admin":
        continue
    for s in b.get("subjects") or []:
        if s.get("kind") == "User" and s.get("name") == user:
            via = [name] if name in planned_crbs else []
        elif s.get("kind") == "Group" and s.get("name") in groups:
            via = ([name] if name in planned_crbs else []) + (["Group " + s["name"]] if s["name"] in planned_groups else [])
        else:
            continue
        if via:
            lost += via
        else:
            kept.append(name)
if lost and not kept:
    print(" ".join(sorted(set(lost))))' "$who" "$groups" "$3")"
  [ -z "$lost" ] || die "$2: $who is cluster-admin only through objects the uninstall deletes ($lost); sign in as a user with another cluster-admin binding"
}

say "checks"
cluster_login_ok "$hub"; check_api "$hub"
[ "$step" = hub ] || { cluster_login_ok "$site"; check_api "$site"; }
check_admin "$hub_kc" "$hub"
[ "$step" = hub ] || check_admin "$site_kc" "$site"
if [ "$step" = hub ]; then warn_idp "$hub_kc" "$hub"; else warn_idp "$site_kc" "$site"; fi

# --- deleting -------------------------------------------------------------
del() { # KUBECONFIG ARGS...
  local kc=$1; shift
  if $dry_run; then echo "would delete: $*"; return 0; fi
  local out
  # A kind whose CRD is already gone has no objects left (the ACM agent's removal takes its CRDs).
  if ! out="$(oc --kubeconfig "$kc" delete "$@" --ignore-not-found --wait=false 2>&1)"; then
    case "$out" in *"doesn't have a resource type"*) return 0 ;; esac
    printf '%s\n' "$out" >&2; return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}
wait_gone() { # KUBECONFIG SECONDS DESCRIPTION GET-ARGS...
  local kc=$1 secs=$2 what=$3; shift 3
  $dry_run && return 0
  for _ in $(seq 1 $((secs / 10))); do
    [ -z "$(oc --kubeconfig "$kc" get "$@" --ignore-not-found -o name 2>/dev/null)" ] && return 0; sleep 10
  done
  echo "warning: $what still present after ${secs}s" >&2
}
del_subscription() { # KUBECONFIG KIND NAME NAMESPACE: an operator Subscription and its CSV, unless protected
  local kc=$1 kind=$2 name=$3 ns=$4 pkg csv
  pkg="$(oc --kubeconfig "$kc" get "$kind" "$name" -n "$ns" -o jsonpath='{.spec.name}' 2>/dev/null || true)"
  [ -n "$pkg" ] || return 0 # already gone
  case " $protect_pkgs rhbk-operator openshift-cert-manager-operator nfd gpu-operator-certified " in
    *" $pkg "*) echo "kept (protected package): $pkg"; return 0 ;;
  esac
  csv="$(oc --kubeconfig "$kc" get "$kind" "$name" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  del "$kc" "$kind" "$name" -n "$ns"
  [ -z "$csv" ] || del "$kc" clusterserviceversions.operators.coreos.com "$csv" -n "$ns"
}
sweep_ns() { # KUBECONFIG NAMESPACE...: namespaces the install created that Argo CD's inventory doesn't list
  local kc=$1 ns s; shift
  for ns in "$@"; do
    case " $protect_ns keycloak cert-manager cert-manager-operator openshift-cert-manager-operator openshift-nfd nvidia-gpu-operator openshift-config openshift-authentication " in
      *" $ns "*) echo "kept (protected namespace): $ns"; continue ;;
    esac
    oc --kubeconfig "$kc" get ns "$ns" >/dev/null 2>&1 || continue
    for s in $(oc --kubeconfig "$kc" get subscriptions.operators.coreos.com -n "$ns" -o name 2>/dev/null); do
      del_subscription "$kc" subscriptions.operators.coreos.com "${s#*/}" "$ns"
    done
    del "$kc" ns "$ns"
  done
}
run_plan() { # KUBECONFIG PLANFILE GROUP...: delete one group at a time, waiting for each
  local kc=$1 plan=$2; shift 2
  local group kind ns name
  for group in "$@"; do
    grep -q "^$group	" "$plan" || continue
    say "plan: $group"
    while IFS=$'\t' read -r g kind ns name; do
      [ "$g" = "$group" ] || continue
      [ "$ns" != - ] || ns=""
      if [ "$kind" = Subscription.v1alpha1.operators.coreos.com ]; then del_subscription "$kc" "$kind" "$name" "$ns"
      elif [ -n "$ns" ]; then del "$kc" "$kind" "$name" -n "$ns"
      else del "$kc" "$kind" "$name"; fi
      # ACM refuses to delete MultiClusterHub while MultiClusterObservability exists, so the
      # acm group goes one object at a time, in the plan's order (proto-hub, 2026-11-10).
      if [ "$group" = acm ]; then
        if [ -n "$ns" ]; then wait_gone "$kc" 1800 "$kind $ns/$name" "$kind" "$name" -n "$ns"
        else wait_gone "$kc" 1800 "$kind $name" "$kind" "$name"; fi
      fi
    done < "$plan"
    while IFS=$'\t' read -r g kind ns name; do
      [ "$g" = "$group" ] || continue
      [ "$ns" != - ] || ns=""
      if [ -n "$ns" ]; then wait_gone "$kc" 900 "$kind $ns/$name" "$kind" "$name" -n "$ns"
      else wait_gone "$kc" 900 "$kind $name" "$kind" "$name"; fi
    done < "$plan"
  done
}
make_plan() { # MODE OUTFILE
  local args=(--mode "$1" --protect-namespaces "$protect_ns" --protect-packages "$protect_pkgs")
  [ "$1" = site ] && args+=(--site "$site")
  H get applications.argoproj.io -n openshift-gitops -o json | python3 "$here/uninstall-plan.py" "${args[@]}" > "$2"
  echo "$(wc -l < "$2" | tr -d ' ') objects planned (Argo CD inventory):"
  sed 's/^/  /' "$2"
}

drop_dangling_webhooks() { # KUBECONFIG: webhooks whose services all live in deleted namespaces
  # Their failurePolicy is often Fail, so they'd reject writes a reinstall makes
  # (proto-hub, 2026-11-10: ACM discovery, External Secrets, HyperShift).
  local kc=$1 kind name nss ns live
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    { oc --kubeconfig "$kc" get "$kind" -o json 2>/dev/null || true; } | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
for w in (json.loads(raw) if raw else {}).get("items", []):
    nss = {h["clientConfig"]["service"]["namespace"] for h in w.get("webhooks") or [] if h.get("clientConfig", {}).get("service")}
    if nss: print(w["metadata"]["name"], " ".join(sorted(nss)))' | while read -r name nss; do
      live=false
      for ns in $nss; do oc --kubeconfig "$kc" get ns "$ns" >/dev/null 2>&1 && live=true; done
      $live || del "$kc" "$kind" "$name"
    done || true
  done
}
sweep_leftovers() { # KUBECONFIG STEP: the objects in uninstall-leftovers.tsv for this step
  local kc=$1 want=$2 step kind ns target flags names n mgrs
  local prot=" $protect_ns keycloak cert-manager cert-manager-operator openshift-cert-manager-operator openshift-nfd nvidia-gpu-operator openshift-config openshift-authentication "
  while IFS=$'\t' read -r step kind ns target flags; do
    case "$step" in ''|'#'*) continue ;; esac
    [ "$step" = "$want" ] || continue
    local nsargs=(); [ "$ns" = - ] || { case "$prot" in *" $ns "*) continue ;; esac; nsargs=(-n "$ns"); }
    case "$target" in
      label:*) names="$(oc --kubeconfig "$kc" get "$kind" ${nsargs[@]+"${nsargs[@]}"} -l "${target#label:}" -o name 2>/dev/null || true)" ;;
      all) names="$(oc --kubeconfig "$kc" get "$kind" ${nsargs[@]+"${nsargs[@]}"} -o name 2>/dev/null || true)" ;;
      prefix:*) names="$(oc --kubeconfig "$kc" get "$kind" ${nsargs[@]+"${nsargs[@]}"} -o name 2>/dev/null | awk -F/ -v p="${target#prefix:}" 'index($2, p) == 1' || true)" ;;
      *) names="$(oc --kubeconfig "$kc" get "$kind" "$target" ${nsargs[@]+"${nsargs[@]}"} -o name 2>/dev/null || true)" ;;
    esac
    for n in $names; do
      case "$flags" in
        managed-by:*)
          mgrs="$(oc --kubeconfig "$kc" get "$n" ${nsargs[@]+"${nsargs[@]}"} -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || true)"
          case " $mgrs " in *" ${flags#managed-by:} "*) ;; *) echo "kept (not written by ${flags#managed-by:}): $n"; continue ;; esac ;;
        strip) $dry_run || oc --kubeconfig "$kc" patch "$n" ${nsargs[@]+"${nsargs[@]}"} --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true ;;
      esac
      del "$kc" "$n" ${nsargs[@]+"${nsargs[@]}"}
    done
  done < "$here/uninstall-leftovers.tsv"
}
drop_dangling_console_plugins() { # KUBECONFIG: enabled plugins with no ConsolePlugin; ConsolePlugins whose backend namespace is gone
  local kc=$1 p ns keep=()
  for p in $(oc --kubeconfig "$kc" get consoleplugins.console.openshift.io -o jsonpath='{range .items[*]}{.metadata.name}={.spec.backend.service.namespace}{"\n"}{end}' 2>/dev/null || true); do
    ns=${p#*=}; [ -z "$ns" ] || oc --kubeconfig "$kc" get ns "$ns" >/dev/null 2>&1 || del "$kc" consoleplugins.console.openshift.io "${p%%=*}"
  done
  local enabled; enabled="$(oc --kubeconfig "$kc" get consoles.operator.openshift.io cluster -o jsonpath='{range .spec.plugins[*]}{@}{"\n"}{end}' 2>/dev/null || true)"
  [ -n "$enabled" ] || return 0
  local changed=false
  for p in $enabled; do
    if oc --kubeconfig "$kc" get consoleplugins.console.openshift.io "$p" >/dev/null 2>&1; then keep+=("$p"); else changed=true; echo "console plugin $p has no ConsolePlugin: disabling it"; fi
  done
  $changed || return 0
  $dry_run && return 0
  oc --kubeconfig "$kc" patch consoles.operator.openshift.io cluster --type merge \
    -p "$(python3 -c 'import json, sys; print(json.dumps({"spec": {"plugins": sys.argv[1:]}}))' ${keep[@]+"${keep[@]}"})" >/dev/null
}
load_plan() { # MODE OUTFILE: the saved plan if --plan-file has one, else a new plan (saved there)
  if [ -n "$plan_file" ] && [ -s "$plan_file" ]; then
    cp "$plan_file" "$2"
    echo "$(wc -l < "$2" | tr -d ' ') objects planned (saved in $plan_file by an earlier run):"
    sed 's/^/  /' "$2"
  else
    make_plan "$1" "$2"
    if [ -n "$plan_file" ] && ! $dry_run; then cp "$2" "$plan_file"; echo "plan saved to $plan_file"; fi
  fi
}

# --- site -----------------------------------------------------------------
if [ "$step" = site ]; then
  managed=false
  if H get managedcluster "$site" >/dev/null 2>&1; then
    managed=true
    name="$(S get klusterlet klusterlet -o jsonpath='{.spec.clusterName}' 2>/dev/null || true)"
    [ -z "$name" ] || [ "$name" = "$site" ] || die "the site's klusterlet says it's $name, not $site"
  fi

  say "inventory of $site"
  load_plan site "$tmp/plan"
  login_binding_kept "$site_kc" "$site" "$tmp/plan"

  if $managed; then
    say "hub: stop managing $site"
    if $dry_run; then echo "would remove labels ai-grid/enabled and ai-grid/role from managedcluster $site"
    else H label managedcluster "$site" ai-grid/enabled- ai-grid/role- >/dev/null; fi
    $dry_run || for _ in $(seq 1 30); do
      left="$(H get applications.argoproj.io -n openshift-gitops -o json | python3 -c '
import json, sys
site = sys.argv[1]
for a in json.load(sys.stdin)["items"]:
    d = a["spec"].get("destination", {})
    if (d.get("name") == site or d.get("server", "").rstrip("/").endswith("/" + site)) and not a["metadata"]["name"].startswith("acm-submariner"):
        print(a["metadata"]["name"])' "$site")"
      [ -z "$left" ] && break; sleep 10
    done
    say "hub: remove $site's Submariner add-on"
    # Before the detach, so the add-on uninstalls Submariner while its operator runs;
    # the detach alone removes the operator first and leaves Submariner's cleanup finalizers.
    del "$hub_kc" managedclusteraddons.addon.open-cluster-management.io submariner -n "$site"
    wait_gone "$hub_kc" 600 "$site's Submariner add-on" managedclusteraddons.addon.open-cluster-management.io submariner -n "$site"
    wait_gone "$site_kc" 600 "Submariner on $site" ns submariner-operator
    say "hub: detach $site from ACM"
    del "$hub_kc" managedcluster "$site"
    wait_gone "$hub_kc" 900 "ManagedCluster $site" managedcluster "$site"
    # Argo CD cluster Secrets and the grid identity that outlive the detach (F5).
    for s in $(H get secrets -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster -o json | python3 -c '
import base64, json, sys
for x in json.load(sys.stdin)["items"]:
    if base64.b64decode(x.get("data", {}).get("name", "")).decode() == sys.argv[1]:
        print(x["metadata"]["name"])' "$site"); do del "$hub_kc" secret "$s" -n openshift-gitops; done
    del "$hub_kc" certificates.cert-manager.io "grid-site-$site" -n redhat-ai-grid
    del "$hub_kc" secret "grid-site-$site" -n redhat-ai-grid
    # The detach removes the site's ACM agent; wipe-site.sh refuses while it's there.
    wait_gone "$site_kc" 600 "the site's ACM agent" ns open-cluster-management-agent
  else
    echo "$site isn't a ManagedCluster on the hub; going straight to the site."
  fi

  say "site: OpenShift AI, MaaS, the grid and their operators (wipe-site.sh)"
  wipe=(bash "$here/wipe-site.sh" --kubeconfig "$site_kc")
  if $dry_run; then wipe+=(--dry-run); $managed && wipe+=(--assume-detached); fi
  "${wipe[@]}"

  say "site: everything else the install applied"
  run_plan "$site_kc" "$tmp/plan" policies custom-resources objects cluster-scoped operators namespaces

  # Left by the ACM import, the hub's Policies and the operators, outside Argo CD's
  # inventory (dry run on site-b, 2026-11-10). The Klusterlet goes first, while its
  # operator still runs to remove the agent.
  say "site: ACM agent and other leftovers"
  if S get klusterlet klusterlet >/dev/null 2>&1; then
    del "$site_kc" klusterlet klusterlet
    wait_gone "$site_kc" 300 "Klusterlet" klusterlet klusterlet
  fi
  sweep_ns "$site_kc" open-cluster-management-agent open-cluster-management-agent-addon submariner-operator \
    open-cluster-management-policies open-cluster-management "$site" ai-tenants redhat-ai-gateway-infra

  say "site: webhooks left pointing at deleted namespaces"
  drop_dangling_webhooks "$site_kc"
  say "site: operator leftovers outside the deleted namespaces (uninstall-leftovers.tsv)"
  sweep_leftovers "$site_kc" site
  drop_dangling_console_plugins "$site_kc"

  say "check: $site"
  $dry_run || check_admin "$site_kc" "$site"
  echo "== done$($dry_run && echo ' (dry run: nothing deleted)')"
  exit 0
fi

# --- hub ------------------------------------------------------------------
sites="$(H get managedclusters -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -vx local-cluster || true)"
if [ -n "$sites" ]; then
  $dry_run || die "sites are still managed (uninstall each with uninstall.sh site NAME first): $(echo $sites)"
  echo "warning: sites are still managed ($(echo $sites)); the real run refuses until each is uninstalled"
fi
[ "$(H get managedcluster local-cluster -o jsonpath='{.metadata.labels.ai-grid/enabled}' 2>/dev/null)" != true ] ||
  die "local-cluster is labelled ai-grid/enabled: a hub that is also a site isn't supported yet"

say "inventory of the hub"
load_plan hub "$tmp/plan"
login_binding_kept "$hub_kc" "$hub" "$tmp/plan"

say "stop Argo CD (ApplicationSets orphan their Applications; Applications lose their finalizers)"
# In rounds until nothing is left: an Application that's still there (the deployment's
# root) self-heals the ApplicationSets back while the others are deleted (proto-hub,
# 2026-11-10), and those regenerate every Application.
stop_argo_round() {
  local a
  for a in $(H get applications.argoproj.io -n openshift-gitops -o name 2>/dev/null); do
    if $dry_run; then echo "would remove finalizers and delete: $a"
    else H patch "$a" -n openshift-gitops --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; fi
  done
  $dry_run || H delete applications.argoproj.io --all -n openshift-gitops --ignore-not-found --wait=false >/dev/null
  for a in $(H get applicationsets.argoproj.io -n openshift-gitops -o name 2>/dev/null); do del "$hub_kc" "$a" -n openshift-gitops --cascade=orphan; done
}
argo_left() { H get applications.argoproj.io,applicationsets.argoproj.io -n openshift-gitops -o name 2>/dev/null; }
if $dry_run; then stop_argo_round
else
  quiet=0
  for round in $(seq 1 20); do
    if [ -z "$(argo_left)" ]; then quiet=$((quiet + 1)); [ "$quiet" -ge 2 ] && break
    else quiet=0; stop_argo_round; fi
    sleep 15
  done
  [ -z "$(argo_left)" ] || die "Argo CD keeps recreating its Applications; stop it by hand and rerun"
  echo "Argo CD has no Applications or ApplicationSets left (round $round)."
fi

run_plan "$hub_kc" "$tmp/plan" policies custom-resources acm
if H get multiclusterengines.multicluster.openshift.io >/dev/null 2>&1; then
  say "multicluster engine"
  for m in $(H get multiclusterengines.multicluster.openshift.io -o name); do del "$hub_kc" "$m"; done
  wait_gone "$hub_kc" 1200 "MultiClusterEngine" multiclusterengines.multicluster.openshift.io
  for s in $(H get subscriptions.operators.coreos.com -n multicluster-engine -o name 2>/dev/null); do
    csv="$(H get "$s" -n multicluster-engine -o jsonpath='{.status.installedCSV}')"
    del "$hub_kc" "$s" -n multicluster-engine; [ -z "$csv" ] || del "$hub_kc" csv "$csv" -n multicluster-engine
  done
fi
run_plan "$hub_kc" "$tmp/plan" objects cluster-scoped operators namespaces

say "ACM leftovers (Red Hat's ACM 2.17 cleanup list)"
for r in "apiservice v1.admission.cluster.open-cluster-management.io" "apiservice v1.admission.work.open-cluster-management.io" \
         "mutatingwebhookconfiguration ocm-mutating-webhook" "mutatingwebhookconfiguration managedclustermutators.admission.cluster.open-cluster-management.io" \
         "mutatingwebhookconfiguration multicluster-observability-operator" \
         "validatingwebhookconfiguration channels.apps.open.cluster.management.webhook.validator" "validatingwebhookconfiguration application-webhook-validator" \
         "validatingwebhookconfiguration multiclusterhub-operator-validating-webhook" "validatingwebhookconfiguration ocm-validating-webhook" \
         "validatingwebhookconfiguration multicluster-observability-operator" "validatingwebhookconfiguration multiclusterengines.multicluster.openshift.io"; do
  # shellcheck disable=SC2086
  if H get $r >/dev/null 2>&1; then del "$hub_kc" $r; fi
done
sweep_ns "$hub_kc" multicluster-engine open-cluster-management-hub open-cluster-management-observability

# Left by ACM's add-ons, the multicluster engine and the operators, outside Argo CD's
# inventory (dry run on proto-hub, 2026-11-10).
say "hub: other leftovers"
sweep_ns "$hub_kc" default-broker submariner-operator openshift-cluster-observability-operator external-secrets \
  ai-grid-internal-models redhat-ods-operator hive hypershift local-cluster

say "OpenShift GitOps"
# The operator recreates its default instance when it's deleted (proto-hub, 2026-11-10),
# so tell it to stop and let it remove the instance, finalizer and cluster RBAC included.
if $dry_run; then echo "would set DISABLE_DEFAULT_ARGOCD_INSTANCE=true on subscription openshift-gitops-operator"
elif H get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator >/dev/null 2>&1; then
  H patch subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator --type merge \
    -p '{"spec":{"config":{"env":[{"name":"DISABLE_DEFAULT_ARGOCD_INSTANCE","value":"true"}]}}}' >/dev/null
fi
for a in $(H get argocds.argoproj.io -A -o name 2>/dev/null); do del "$hub_kc" "$a" -n openshift-gitops; done
wait_gone "$hub_kc" 600 "ArgoCD" argocds.argoproj.io -A
csv="$(H get subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
del "$hub_kc" subscriptions.operators.coreos.com openshift-gitops-operator -n openshift-gitops-operator
[ -z "$csv" ] || del "$hub_kc" csv "$csv" -n openshift-gitops-operator
for ns in openshift-gitops openshift-gitops-operator; do
  if H get ns "$ns" >/dev/null 2>&1; then del "$hub_kc" ns "$ns"; fi
done
# If an instance outlived its operator, nothing runs its finalizer: drop it, and the
# instance's cluster RBAC the finalizer would have removed.
if ! $dry_run; then
  for a in $(H get argocds.argoproj.io -A -o name 2>/dev/null); do
    H patch "$a" -n openshift-gitops --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  for r in $(H get clusterroles,clusterrolebindings -o name 2>/dev/null | grep -E '/openshift-gitops-' || true); do del "$hub_kc" "$r"; done
fi
wait_gone "$hub_kc" 900 "GitOps namespaces" ns openshift-gitops openshift-gitops-operator

say "hub: webhooks left pointing at deleted namespaces"
drop_dangling_webhooks "$hub_kc"
say "hub: operator leftovers outside the deleted namespaces (uninstall-leftovers.tsv)"
sweep_leftovers "$hub_kc" hub
drop_dangling_console_plugins "$hub_kc"

say "check: $hub"
$dry_run || check_admin "$hub_kc" "$hub"
echo "== done$($dry_run && echo ' (dry run: nothing deleted)')"
