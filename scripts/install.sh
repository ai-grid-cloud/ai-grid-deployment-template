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
#                    scripts/set-inputs.sh CATALOG_REPO_URL, then
#                    scripts/git-push.sh of root/ and the tenant IdP settings
#   catalog          scripts/empty-catalog.sh --check: the catalog repository
#                    must hold nothing but its README; the install never empties it
#   bootstrap        scripts/bootstrap-hub.sh, unless Application deployment-root
#                    exists; then gate hub-root: deployment-root Synced at the
#                    pushed commit
#   acm              gate hub-acm: the MultiClusterHub is Running
#   console-secrets  scripts/create-console-secrets.sh, unless Secret
#                    ai-grid-provider-console/ai-grid-backend-git exists
#   hub-apps         gate hub-apps: every hub Application Synced and Healthy,
#                    except those waiting for a site
# Then the sites phase (sites_phase below), unless --hub-only.
#
# On a failed gate it runs scripts/install-report.sh, prints
# "make install stopped at GATE. Fix the cause, then run make install again."
# and exits 1. A failed step stops the same way, naming the step.
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
step() { echo "== $1"; }
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
    value=${value%%[[:space:]]#*}                                          # a trailing comment
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value=${BASH_REMATCH[1]}
    case "$value" in *REQUIRED-*) left+="${left:+, }$key" ;; esac
    printf -v "$key" '%s' "$value"; export "${key?}"
  done < "$f"
  [ -z "$left" ] || die "set these in install.env: $left"
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
  die "can't read the hub: ${out#oc error: }"
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
  run_step inputs git-push.sh "install: inputs and library pin" root/ tenant-idp/manifests/settings.yaml
  pushed=$(git -C "$dir" rev-parse HEAD)
}

step_catalog() {
  step catalog
  run_step catalog empty-catalog.sh --check
}

step_bootstrap() {
  step bootstrap
  if exists applications.argoproj.io deployment-root -n openshift-gitops; then
    echo "deployment-root exists: the hub is bootstrapped."
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

# Tasks D1 and D2 add the sites here: each site's files and issuer check, its
# import, and its gate, in clusters.yaml order.
sites_phase() {
  :
}

# --- main --------------------------------------------------------------------

cd "$dir"
read_install_env
check_install_env
. "$here/clusters.sh"
clusters_load "$dir"
. "$here/gates.sh"   # after install.env, so its GATE_* values win
pushed=""

hub_phase
[ -n "$hub_only" ] || sites_phase
echo "make install: done."
