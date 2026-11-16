#!/usr/bin/env bash
# The hands-off install (make install): from blank OpenShift clusters to an
# installed hub, with no prompt and no browser. It chains the template's own
# scripts and, between them, waits on the readiness gates in scripts/gates.sh.
# Every step first checks whether its work is already done, so after a failure
# you fix the cause and run it again.
#
# Reads its settings from clusters.yaml at the root of this repository
# (repositories: and options:; scripts/clusters.sh
# settings_lines) and stops before any cluster call when a REQUIRED- value is
# left in it, or a file it names doesn't exist. Relative paths in it are
# relative to this repository. A setting the file holds, even an empty one,
# wins over the environment's; one it leaves out comes from the environment,
# else its default. An install.env, which earlier versions read, stops it.
# Secrets come from scripts/clusters.sh's deployment_load: the environment,
# else the private .config/clusters.yaml, else the files of earlier versions.
# Each reaches the scripts as a file passed by path (DEPLOYMENT_TOKEN_FILE to
# scripts/git-push.sh, CATALOG_TOKEN_FILE to scripts/create-console-secrets.sh,
# QUAY_AUTH_FILE to scripts/bootstrap-hub.sh), never on a command line or in
# the output. It only checks, before anything is pushed, that QUAY_AUTH_FILE holds
# a quay.io/rhoai login, or that ALLOW_GENERIC_LOGIN=1 lets the general one stand in.
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
#   console-secrets  scripts/create-console-secrets.sh, on every run: it's
#                    safe to rerun
#   hub-apps         gate hub-apps: every hub Application Synced and Healthy,
#                    except those waiting for a site
# Then the sites phase, unless --hub-only. Ingress and combined sites keep the
# chart's internal certificate on the MaaS gateway, as upstream does; the
# library sets its hostname, maas.<apps domain>.
# Then for each site in clusters.yaml order:
#   site NAME        scripts/site-check.sh NAME, scripts/import-site.sh NAME --yes,
#                    then gate site-NAME-import: ManagedCluster NAME available
# then gate hub-apps-final: every hub Application Synced and Healthy, except
# those waiting for a site. Last:
#   provider-admin   scripts/provider-admin.sh: the provider-admin
#                    ServiceAccount and its token in .config/provider-admin-token
#   ready            gate ready: scripts/ready-check.sh passes. It's a one-shot
#                    check, so the gate reruns it until it passes or
#                    GATE_READY_SECONDS (default 600) pass, for late Routes and
#                    endpoints. Each run's output goes to .install/ready-check.txt;
#                    on failure its FAIL lines are printed above the stop line.
# and prints "Installed. Outputs: .install/outputs.json".
#
# With --hub-only it stops after hub-apps: no sites, no provider-admin and no
# ready check, because the ready check asserts every site is imported.
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

# --- settings ----------------------------------------------------------------

check_old_files() { # an install.env, which earlier versions read, stops the install
  [ ! -f "$dir/install.env" ] ||
    die "install.env is no longer read: move its settings into clusters.yaml (CATALOG_REPO_URL and LIBRARY_REVISION under repositories: as catalog and library, the rest under options:; see clusters-example.yaml), then delete install.env"
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

check_settings() { # the values the hub phase needs, and the files they name
  [ -n "${CATALOG_REPO_URL:-}" ] || die "set repositories.catalog in ${CLUSTERS_FILE#"$dir/"}"
  case "${KEYCLOAK:-install}" in
    install) ;;
    *) die "KEYCLOAK=${KEYCLOAK} is not supported yet: only KEYCLOAK=install is" ;;
  esac
  local var
  for var in DEPLOYMENT_TOKEN_FILE CATALOG_TOKEN_FILE QUAY_AUTH_FILE; do
    [ -n "${!var}" ] && [ -s "${!var}" ] || die "no ${var%_FILE}: $(secret_missing "$var")"
  done
  # bootstrap-hub.sh's own login check, made here so a missing login stops the
  # install before the inputs step pushes anything. It reads which logins the
  # file holds, never a token.
  jq -e '.auths["quay.io/rhoai"].auth' "$QUAY_AUTH_FILE" >/dev/null 2>&1 && return 0
  [ "${ALLOW_GENERIC_LOGIN:-${RHOAI_QUAY_ALLOW_GENERIC_LOGIN:-}}" = 1 ] ||
    die "no quay.io/rhoai login in $QUAY_AUTH_FILE; add a robot token for quay.io/rhoai, or set ALLOW_GENERIC_LOGIN=1 to use the general quay.io login"
  jq -e '.auths["quay.io"].auth' "$QUAY_AUTH_FILE" >/dev/null 2>&1 || die "no quay.io login in $QUAY_AUTH_FILE"
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
    echo "error: root/inputs.env names the catalog $have, but clusters.yaml's repositories.catalog is $want; set-inputs.sh keeps a value that's set. Edit catalogRepoURL in root/inputs.env, or delete that line so set-inputs.sh writes it again." >&2
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
  run_step console-secrets create-console-secrets.sh
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

# Each site from clusters.yaml, in file order, then the hub's Applications
# again. hub-apps-final, like the ready check (scripts/ready-check.sh), lets
# through the Applications that wait for a site: no site is in the grid yet.
sites_phase() {
  local name
  for name in $(site_names); do step_site "$name"; done
  hub_gate hub-apps-final "$GATE_HUB_APPS_SECONDS" apps_healthy
}

# --- end ---------------------------------------------------------------------

# Its output file is named from ready_out, a global: gate() has a local $dir of
# its own, which a check it calls would see instead of this script's.
ready_out="$dir/.install/ready-check.txt"
ready_now() { # a gate check: scripts/ready-check.sh passes; its output in $ready_out
  local f=$ready_out n
  mkdir -p "${ready_out%/*}"
  "$here/ready-check.sh" > "$f" 2>&1 && return 0
  n=$(grep -c '^FAIL' "$f" || true)
  if [ "$n" -gt 0 ]; then echo "$n FAIL; first: $(grep -m 1 '^FAIL' "$f")"
  else echo "ready-check.sh: $(grep . "$f" | tail -n 1)"; fi
  return 1
}

end_phase() {
  step provider-admin
  run_step provider-admin provider-admin.sh
  step ready
  gate ready "$GATE_READY_SECONDS" ready_now && return 0
  bash "$here/install-report.sh" ready || true
  echo "== the ready check's last run (.install/ready-check.txt)"
  grep -E '^(FAIL|WARN)' "$ready_out" || tail -n 5 "$ready_out"
  stopped ready
}

# --- main --------------------------------------------------------------------

cd "$dir"
. "$here/clusters.sh"
check_old_files
deployment_load "$dir" || exit 1
check_settings
check_branch
. "$here/gates.sh"   # after the settings, so their GATE_* values win
pushed=""

hub_phase
if [ -n "$hub_only" ]; then
  echo "make install --hub-only: the hub is installed (hub only: no sites, provider-admin or ready check)."
  exit 0
fi
sites_phase
end_phase
echo "Installed. Outputs: .install/outputs.json"
