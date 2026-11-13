#!/usr/bin/env bash
# The hands-off install (make install): from blank OpenShift clusters to an
# installed hub, with no prompt and no browser. It chains the template's own
# scripts and, between them, waits on the readiness gates in scripts/gates.sh.
# Every step first checks whether its work is already done, so after a failure
# you fix the cause and run it again.
#
# Reads install.env at the root of this repository (copied from
# install-example.env) and stops before any cluster call when a REQUIRED-
# value is left in it, or a file it names doesn't exist. Relative paths in it
# are relative to this repository, and its values win over the environment's.
# The token files are passed on by path (DEPLOYMENT_TOKEN_FILE to
# scripts/git-push.sh, CATALOG_TOKEN_FILE to scripts/create-console-secrets.sh,
# QUAY_AUTH_FILE to scripts/bootstrap-hub.sh); this script never reads them.
#
# The hub phase, each step printing "== STEP":
#   login            scripts/login.sh --non-interactive
#   inputs           scripts/set-library.sh LIBRARY_REVISION (when set),
#                    scripts/set-inputs.sh CATALOG_REPO_URL, a check that
#                    root/inputs.env names the same catalog, then
#                    scripts/git-push.sh of root/ and the tenant IdP settings
#   catalog          scripts/empty-catalog.sh --check: the catalog repository
#                    must hold nothing but its README; the install never empties it
#   bootstrap        scripts/bootstrap-hub.sh, unless Application deployment-root
#                    and the hub pull secret it seeds last
#                    (rhoai-prerequisites/rhoai-quay-pull-secret) both exist;
#                    then gate hub-root: deployment-root Synced at the pushed commit
#   acm              gate hub-acm: the MultiClusterHub is Running
#   console-secrets  scripts/create-console-secrets.sh, unless Secret
#                    ai-grid-provider-console/ai-grid-backend-git exists
#   hub-apps         gate hub-apps: every hub Application Synced and Healthy,
#                    except those waiting for a site
# Then the sites phase, unless --hub-only. First, what a later console Add needs
# (install guide, page 6):
#   site-files       each ingress or combined site needs a DNS-01 ClusterIssuer
#                    for its MaaS certificate, read with the site's login; with
#                    one, scripts/add-site.sh NAME; with several, the one named
#                    by SITE_ISSUER_<NAME> in install.env (the site's name upper-
#                    cased, - as _, so site-b is SITE_ISSUER_SITE_B); with none,
#                    it stops. Then one scripts/git-push.sh of apps/ sites/
#                    values/clusters/ and gate hub-root again at the pushed
#                    commit. Inference sites need nothing.
# Then for each site in clusters.yaml order:
#   site NAME        scripts/site-check.sh NAME, scripts/import-site.sh NAME --yes,
#                    then gate site-NAME-import: ManagedCluster NAME available
# and last, gate hub-apps-final: every hub Application Synced and Healthy,
# except those waiting for a site.
#
# Before any cluster call it also checks that this checkout is on the branch
# root/inputs.env names as deploymentRevision (default main), the one the hub
# syncs.
#
# On a failed gate it runs scripts/install-report.sh, prints
# "make install stopped at GATE. Fix the cause, then run make install again."
# and exits 1. A failed step, or an oc error, stops the same way, naming the step.
#
# Usage: scripts/install.sh [--hub-only]
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
hub_only=""
case "${1:-}" in
  "") ;;
  --hub-only) hub_only=1 ;;
  *) echo "usage: install.sh [--hub-only]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }
current=""
step() { current=$1; echo "== $1"; }
stopped() { # NAME: a step or gate stopped the install
  echo "make install stopped at $1. Fix the cause, then run make install again."
  exit 1
}
run_step() { # STEP SCRIPT [ARG...]: runs a script; stops the install at STEP when it fails
  local name=$1 script=$2; shift 2
  "$here/$script" "$@" || stopped "$name"
}

# --- install.env -------------------------------------------------------------

# The settings install.env may hold; anything else is a typo, so it stops.
known_setting() {
  [[ "$1" =~ ^(LIBRARY_REVISION|CATALOG_REPO_URL|DEPLOYMENT_TOKEN_FILE|CATALOG_TOKEN_FILE|QUAY_AUTH_FILE|KEYCLOAK|ALLOW_GENERIC_LOGIN|PROVIDER_ADMIN_TOKEN_DURATION|GATE_[A-Z_]+|SITE_ISSUER_[A-Z0-9_]+)$ ]]
}

read_install_env() { # reads $dir/install.env into exported variables; stops on a problem
  local f="$dir/install.env" line key value left="" n=0
  [ -f "$f" ] || die "no install.env: copy install-example.env to install.env, set its values and commit it"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "install.env line $n isn't NAME=VALUE"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    known_setting "$key" || die "install.env line $n: unknown setting $key"
    value=${value#"${value%%[![:space:]]*}"}
    if [[ "$value" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || "$value" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      value=${BASH_REMATCH[1]}                                             # quoted: kept as is
    else
      value=${value%%[[:space:]]#*}                                        # a trailing comment
      value=${value%"${value##*[![:space:]]}"}
    fi
    [[ "$key" != GATE_* || "$value" =~ ^[0-9]+$ ]] ||
      die "install.env line $n: $key must be a number of seconds"
    case "$value" in *REQUIRED-*) left+="${left:+, }$key" ;; esac
    printf -v "$key" '%s' "$value"; export "${key?}"
  done < "$f"
  [ -z "$left" ] || die "set these in install.env: $left"
}

inputs_value() { # NAME: its value in root/inputs.env, empty when unset
  [ -f "$dir/root/inputs.env" ] && sed -n "s/^$1=//p" "$dir/root/inputs.env" | tail -n1 || true
}

https_url() { # a git remote URL -> https://HOST/OWNER/REPO.git, as scripts/set-inputs.sh writes it
  local u=${1%/}
  case "$u" in
    git@*:*) u="${u#git@}"; u="https://${u/://}" ;;
    ssh://git@*) u="https://${u#ssh://git@}" ;;
  esac
  u=$(sed -E 's#^https://[^@/]+@#https://#' <<<"$u")
  [ "${u%.git}" = "$u" ] && u="$u.git"
  echo "$u"
}

check_branch() { # this checkout must be on deploymentRevision, the branch the hub syncs
  local want branch
  want=$(inputs_value deploymentRevision); want=${want:-main}
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD) || branch="a detached HEAD"
  [ "$branch" = "$want" ] ||
    die "this checkout is on $branch, but root/inputs.env's deploymentRevision is $want, the branch the hub syncs: check out $want, or set deploymentRevision"
}

abs_path() { # PATH: absolute, relative to this repository; ~/ is your home
  case "$1" in
    /*) echo "$1" ;;
    "~/"*) echo "$HOME/${1#"~/"}" ;;
    *) echo "$dir/$1" ;;
  esac
}

check_install_env() { # the values the hub phase needs, and the files they name
  local var f
  [ -n "${CATALOG_REPO_URL:-}" ] || die "set CATALOG_REPO_URL in install.env"
  case "${KEYCLOAK:-install}" in
    install) ;;
    *) die "KEYCLOAK=${KEYCLOAK} is not supported yet: only KEYCLOAK=install is" ;;
  esac
  : "${DEPLOYMENT_TOKEN_FILE:=.config/deployment-token}"
  : "${CATALOG_TOKEN_FILE:=.config/catalog-token}"
  : "${QUAY_AUTH_FILE:=.config/quay-auth.json}"
  for var in DEPLOYMENT_TOKEN_FILE CATALOG_TOKEN_FILE QUAY_AUTH_FILE; do
    f=$(abs_path "${!var}")
    [ -s "$f" ] || die "$var names $f, which doesn't exist or is empty: put the file there (install.env)"
    printf -v "$var" '%s' "$f"; export "${var?}"
  done
}

# --- hub phase ---------------------------------------------------------------

hub_gate() { # NAME TIMEOUT CHECK [ARG...]: waits on a gate; on failure, the report and stop
  local name=$1
  gate "$@" && return 0
  bash "$here/install-report.sh" "$name" || true
  stopped "$name"
}

exists() { # oc get ARG...: 0 when the object exists, 1 when not; stops on an oc error
  local out rc
  out=$(oc_read get "$@" -o name) && return 0 || rc=$?
  [ "$rc" = 1 ] && return 1
  echo "error: can't read the hub: ${out#oc error: }" >&2
  stopped "$current"
}

step_login() {
  step login
  run_step login login.sh --non-interactive
  KUBECONFIG=$(cluster_kubeconfig "$(hub_name)"); export KUBECONFIG
}

step_inputs() {
  step inputs
  [ -z "${LIBRARY_REVISION:-}" ] || run_step inputs set-library.sh "$LIBRARY_REVISION"
  run_step inputs set-inputs.sh "$CATALOG_REPO_URL"
  local have want
  have=$(https_url "$(inputs_value catalogRepoURL)") want=$(https_url "$CATALOG_REPO_URL")
  if [ "$have" != "$want" ]; then
    echo "error: root/inputs.env names the catalog $have, but install.env's CATALOG_REPO_URL is $want; set-inputs.sh keeps a value that's set. Edit catalogRepoURL in root/inputs.env, or delete that line so set-inputs.sh writes it again." >&2
    stopped inputs
  fi
  run_step inputs git-push.sh "install: inputs and library pin" root/ tenant-idp/manifests/settings.yaml
  pushed=$(git -C "$dir" rev-parse HEAD)
}

step_catalog() {
  step catalog
  run_step catalog empty-catalog.sh --check
}

step_bootstrap() {
  step bootstrap
  # bootstrap-hub.sh seeds the pull secret (the library's
  # apps/rhoai-prerequisites/create-hub-secret.sh) after it applies
  # deployment-root, so both must exist for a finished bootstrap.
  if exists applications.argoproj.io deployment-root -n openshift-gitops &&
      exists secret rhoai-quay-pull-secret -n rhoai-prerequisites; then
    echo "deployment-root and the hub pull secret exist: the hub is bootstrapped."
  else
    run_step bootstrap bootstrap-hub.sh
  fi
  hub_gate hub-root "$GATE_ROOT_SECONDS" root_synced_to "$pushed"
}

step_acm() {
  step acm
  hub_gate hub-acm "$GATE_MCH_SECONDS" mch_running
}

step_console_secrets() {
  step console-secrets
  if exists secret ai-grid-backend-git -n ai-grid-provider-console; then
    echo "The console's Secrets exist."
  else
    run_step console-secrets create-console-secrets.sh
  fi
}

step_hub_apps() {
  step hub-apps
  hub_gate hub-apps "$GATE_HUB_APPS_SECONDS" apps_healthy
}

hub_phase() {
  step_login
  step_inputs
  step_catalog
  step_bootstrap
  step_acm
  step_console_secrets
  step_hub_apps
}

# --- sites phase -------------------------------------------------------------

step_site() { # NAME: check the site, import it into the hub's ACM, wait until it's available
  local name=$1
  step "site $name"
  # site-check.sh prints its own OK, MISSING or FOUND lines, a previous install
  # included; they stay above the stop line.
  run_step "site $name" site-check.sh "$name"
  # import-site.sh leaves a site that is already joined and available alone.
  run_step "site $name" import-site.sh "$name" --yes
  hub_gate "site-$name-import" "$GATE_SITE_IMPORT_SECONDS" managedcluster_available "$name"
}

site_issuers() { # NAME: the site's DNS-01 ClusterIssuers, one per line (add-site.sh's filter); 2 on an oc error
  local json rc
  json=$(KUBECONFIG=$(cluster_kubeconfig "$1") oc_read get clusterissuers.cert-manager.io -o json) && rc=0 || rc=$?
  [ "$rc" = 1 ] && return 0                     # no cert-manager, or no ClusterIssuer
  if [ "$rc" != 0 ]; then echo "error: can't read $1's ClusterIssuers: ${json#oc error: }" >&2; return 2; fi
  jq -r '.items[] | select(any(.spec.acme.solvers[]?; .dns01 != null)) | .metadata.name' <<<"$json"
}

# The MaaS files of every ingress and combined site, committed, pushed and
# synced to the hub, so a later console Add of the site finds them.
step_site_files() {
  local name role issuers var chosen n any=""
  step site-files
  for name in $(site_names); do
    role=$(cluster_field "$name" role)
    case "$role" in ingress|combined) ;; *) continue ;; esac
    any=1
    issuers=$(site_issuers "$name") || stopped site-files
    n=$(grep -c . <<<"$issuers" || true)
    var="SITE_ISSUER_$(tr 'a-z-' 'A-Z_' <<<"$name")"
    chosen=${!var:-}
    if [ "$n" = 0 ]; then
      echo "error: $name ($role) has no DNS-01 ClusterIssuer for its MaaS certificate; add one, or give it role inference." >&2
      stopped site-files
    elif [ -n "$chosen" ]; then
      grep -qx -- "$chosen" <<<"$issuers" || {
        echo "error: $var=$chosen isn't a DNS-01 ClusterIssuer on $name; those are: $(echo $issuers)" >&2
        stopped site-files; }
      run_step site-files add-site.sh "$name" "$chosen"
    elif [ "$n" = 1 ]; then
      run_step site-files add-site.sh "$name"
    else
      echo "error: $name has several DNS-01 ClusterIssuers: $(echo $issuers). Set $var in install.env to the one that issues publicly trusted certificates for its apps domain." >&2
      stopped site-files
    fi
  done
  [ -n "$any" ] || { echo "No ingress or combined site: no site files."; return 0; }
  run_step site-files git-push.sh "install: site files" apps/ sites/ values/clusters/
  pushed=$(git -C "$dir" rev-parse HEAD)
  hub_gate hub-root "$GATE_ROOT_SECONDS" root_synced_to "$pushed"
}

# Each site from clusters.yaml, in file order, then the hub's Applications
# again. hub-apps-final still lets through the Applications that wait for a
# site (no --strict): the ready check (scripts/ready-check.sh) is the strict
# one. The acceptance run (Z1) records which Applications, if any, still wait
# for a site at this point.
sites_phase() {
  local name
  step_site_files
  for name in $(site_names); do step_site "$name"; done
  hub_gate hub-apps-final "$GATE_HUB_APPS_SECONDS" apps_healthy
}

# --- main --------------------------------------------------------------------

cd "$dir"
read_install_env
check_install_env
check_branch
. "$here/clusters.sh"
clusters_load "$dir"
. "$here/gates.sh"   # after install.env, so its GATE_* values win
pushed=""

hub_phase
[ -n "$hub_only" ] || sites_phase
echo "make install: done."
