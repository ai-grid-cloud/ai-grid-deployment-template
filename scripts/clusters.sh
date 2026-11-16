#!/usr/bin/env bash
# Reads a deployment repository's clusters.yaml: .config/clusters.yaml when it
# exists (private: git-ignored, mode 600, and the only place secrets may go),
# else clusters.yaml at the root (copied from clusters-example.yaml). It holds
# the hub, and each site with its role, location and API URL; make install's
# settings (repositories:, options:); and, in the private
# file only, the secrets (credentials:, github:, quay:). The hub's name is
# "hub" unless the file names it. Each cluster's login is
# .config/NAME/kubeconfig (git-ignored; make login). kubectl parses the YAML
# offline (--local), and jq reads the result. No error quotes the file's text.
#
# Sourced by the other scripts:
#   clusters_load DIR             reads and checks DIR/.config/clusters.yaml, else DIR/clusters.yaml
#   CLUSTERS_FILE                 the file it read
#   secret_get JQ_PATH            a secret's value, such as .github.catalogToken; empty when unset
#   cluster_secret NAME KEY       credentials.NAME.KEY (token, username, password, kubeconfig)
#   deployment_load DIR           clusters_load, then the settings and the secret files
#                                 exported (see "settings and secrets" below)
#   settings_lines                its install settings, KEY=VALUE per line
#   hub_name, site_names          the hub's name; the sites' names
#   site_name [NAME]              NAME, or the only site when NAME is empty;
#                                 with several sites, asks you to name one
#   cluster_field NAME FIELD      role, location or api
#   cluster_kubeconfig NAME       the path of NAME's kubeconfig
#   merge_kubeconfigs HUB SITE OUT  one kubeconfig with contexts hub and site
#   INSTALL_NS_RE                 an extended regex matching the namespaces an
#                                 install creates on a hub or a site

CLUSTERS_DIR="" CLUSTERS_ROWS="" CLUSTERS_JSON="" CLUSTERS_FILE=""
# The keys clusters.yaml's options: may hold (make install's settings).
SETTINGS_OPTIONS_RE='KEYCLOAK|ALLOW_GENERIC_LOGIN|PROVIDER_ADMIN_TOKEN_DURATION|GATE_ROOT_SECONDS|GATE_MCH_SECONDS|GATE_HUB_APPS_SECONDS|GATE_SITE_IMPORT_SECONDS|GATE_READY_SECONDS|GATE_INTERVAL|GATE_ERROR_LIMIT|GATE_O11Y_SECONDS|GATE_TENANT_IDP_SECONDS'
INSTALL_NS_RE='open-cluster-management|multicluster-engine|redhat-ods|redhat-ai-grid|maas|ai-grid|gitops|kuadrant|submariner'

clusters_load() {
  CLUSTERS_DIR=$(cd "${1:-.}" && pwd)
  local f json rows="" what name role location api left mode private=""
  if [ -f "$CLUSTERS_DIR/.config/clusters.yaml" ]; then f="$CLUSTERS_DIR/.config/clusters.yaml" private=1
  else f="$CLUSTERS_DIR/clusters.yaml"; fi
  CLUSTERS_FILE=$f
  [ -f "$f" ] || { echo "error: no clusters.yaml: copy clusters-example.yaml to .config/clusters.yaml (or clusters.yaml) and edit it (install guide, page 2 or 9)" >&2; return 1; }
  if [ -n "$private" ]; then
    mode=$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")
    [[ "$mode" =~ 00$ ]] || { echo "error: .config/clusters.yaml holds secrets and is mode $mode: run chmod 600 .config/clusters.yaml" >&2; return 1; }
  fi
  # kubectl's message can quote the file, which may hold secrets: keep only its line number.
  if ! json=$(KUBECONFIG=/dev/null kubectl label --local -f "$f" ai-grid.dev/read=true -o json 2>&1); then
    left=$(grep -oE 'line [0-9]+' <<<"$json" | head -n 1 || true)
    echo "error: ${f#"$CLUSTERS_DIR/"} isn't valid YAML${left:+ (at $left)}" >&2; return 1
  fi
  [ "$(jq -r .kind <<<"$json")" = Clusters ] || { echo "error: clusters.yaml needs kind: Clusters" >&2; return 1; }
  # The committed clusters.yaml never holds secrets, whichever file is read.
  if [ -f "$CLUSTERS_DIR/clusters.yaml" ] &&
     ! KUBECONFIG=/dev/null kubectl label --local -f "$CLUSTERS_DIR/clusters.yaml" ai-grid.dev/read=true -o json 2>/dev/null |
       jq -e '[.credentials, .github, .quay] | map(select(. != null)) | length == 0' >/dev/null 2>&1; then
    echo "error: clusters.yaml is committed, so it can't hold credentials:, github: or quay: (or isn't valid YAML): move the secrets to .config/clusters.yaml (chmod 600), which git ignores" >&2
    return 1
  fi
  # Each of these is a map; a value in its place is named by path only, never printed.
  left=$(jq -r '
      ([["options"], ["repositories"], ["hub"], ["credentials"], ["github"], ["quay"]][] as $p
        | select(getpath($p) | . != null and type != "object") | $p | join(".")),
      ((.credentials // {}) | if type == "object" then to_entries[] | select(.value != null and (.value | type) != "object") | "credentials.\(.key)" else empty end),
      ((.sites // []) | if type == "array" then to_entries[] | select((.value | type) != "object") | "sites[\(.key)]" else "sites must be a list" end)
      ' <<<"$json" 2>/dev/null | head -n 1) ||
    { echo "error: ${f#"$CLUSTERS_DIR/"}: can't read its structure" >&2; return 1; }
  case "$left" in
    "") ;;
    *" must be a list") echo "error: ${f#"$CLUSTERS_DIR/"}: $left" >&2; return 1 ;;
    *) echo "error: ${f#"$CLUSTERS_DIR/"}: $left must be a map" >&2; return 1 ;;
  esac
  # Options that named secret files before the secrets moved into the private file.
  left=$(jq -r '(.options // {}) | keys[] | select(. == "DEPLOYMENT_TOKEN_FILE" or . == "CATALOG_TOKEN_FILE" or . == "QUAY_AUTH_FILE")' <<<"$json" | head -n 1)
  case "$left" in
    "") ;;
    DEPLOYMENT_TOKEN_FILE) echo "error: options.$left is no longer read: put the token in github.deploymentToken in .config/clusters.yaml (make secrets), and delete the option" >&2; return 1 ;;
    CATALOG_TOKEN_FILE) echo "error: options.$left is no longer read: put the token in github.catalogToken in .config/clusters.yaml (make secrets), and delete the option" >&2; return 1 ;;
    *) echo "error: options.$left is no longer read: put the quay.io/rhoai robot account in quay.username and quay.password in .config/clusters.yaml (make secrets), and delete the option" >&2; return 1 ;;
  esac
  # A key the scripts don't read is a typo, most likely: name it.
  left=$(jq -r --arg opts "\\A($SETTINGS_OPTIONS_RE)\\z" '
      def count($p): if length == 0 then [] else ["\($p) (\(length) unknown key\(if length > 1 then "s" else "" end))"] end;
      (keys - ["apiVersion", "kind", "metadata", "hub", "sites", "repositories", "options", "credentials", "github", "quay"] | map(.)),
      # In the secret sections a key may itself be a pasted secret: count, never name.
      ((.credentials // {}) | to_entries[] | .key as $n | (.value // {}) | keys
        - ["token", "username", "password", "kubeconfig"] | count("credentials.\($n)")),
      ((.github // {}) | keys - ["deploymentToken", "catalogToken"] | count("github")),
      ((.quay // {}) | keys - ["username", "password"] | count("quay")),
      ((.hub // {}) | keys - ["name", "api"] | map("hub." + .)),
      ((.sites // []) | to_entries[] | .key as $i | (.value // {}) | keys
        - ["name", "role", "location", "api"] | map("sites[\($i)]." + .)),
      ((.repositories // {}) | keys - ["catalog", "library"] | map("repositories." + .)),
      ((.options // {}) | keys | map(select(test($opts) | not)) | map("options." + .))
      | .[]' <<<"$json" | tr '\n' ' ')
  [ -z "$left" ] || { echo "error: clusters.yaml: unknown keys (typos?): ${left% }" >&2; return 1; }
  # Placeholders: a setting's own text; a secret's key, never its value.
  left=$(jq -r '
      (del(.credentials, .github, .quay) | .. | strings | select(test("REQUIRED-")) | match("REQUIRED-[A-Za-z]+").string),
      ({credentials, github, quay} | paths(strings) as $p | select(getpath($p) | test("REQUIRED-"))
        | $p | map(tostring) | join("."))' <<<"$json" | sort -u | tr '\n' ' ')
  [ -z "$left" ] || { echo "error: set these in ${f#"$CLUSTERS_DIR/"}: ${left% }" >&2; return 1; }
  # One tab-separated row per cluster: what (hub or site N), name, role, location, api.
  while IFS=$'\t' read -r what name role location api; do
    [ -n "$name" ] && [ -n "$role" ] && [ -n "$location" ] && [ -n "$api" ] ||
      { echo "error: clusters.yaml: $what needs name$([ "$what" = hub ] || echo ', role, location') and api" >&2; return 1; }
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "error: clusters.yaml: $what name $name isn't a DNS label" >&2; return 1; }
    case "$what:$role" in
      hub:hub|site*:combined|site*:ingress|site*:inference) ;;
      *) echo "error: clusters.yaml: $what role $role isn't combined, ingress or inference" >&2; return 1 ;;
    esac
    [[ "$api" =~ ^https:// ]] || { echo "error: clusters.yaml: $what api $api isn't an https URL" >&2; return 1; }
    case " $(awk '{print $1}' <<<"$rows" | tr '\n' ' ') " in *" $name "*) echo "error: clusters.yaml: the name $name is used twice" >&2; return 1 ;; esac
    rows+="$name $role $location $api"$'\n'
  done < <(jq -r '(["hub", (.hub.name // "hub"), "hub", "-", .hub.api]),
      ((.sites // []) | to_entries[] | ["site \(.key + 1)", .value.name, .value.role, .value.location, .value.api])
      | map(. // "" | tostring) | @tsv' <<<"$json")
  [ -n "$rows" ] || { echo "error: clusters.yaml has no hub" >&2; return 1; }
  # The private file is for make install, which needs the catalog: say so now, not later.
  [ -z "$private" ] || [ -n "$(jq -r '.repositories.catalog // empty' <<<"$json")" ] ||
    { echo "error: set repositories.catalog in .config/clusters.yaml" >&2; return 1; }
  left=$(jq -r --arg names "$(awk '{print $1}' <<<"$rows")" '
      ($names | split("\n")) as $n | (.credentials // {}) | keys - $n | .[]' <<<"$json" | tr '\n' ' ')
  [ -z "$left" ] || { echo "error: ${f#"$CLUSTERS_DIR/"}: credentials for clusters it doesn't name: ${left% }" >&2; return 1; }
  CLUSTERS_ROWS=$rows CLUSTERS_JSON=$json
}

secret_get() { # JQ_PATH: the secret's value on stdout, empty when unset; it never reaches a command line
  jq -r "($1) // empty | if type == \"string\" then . else error(\"not a string\") end" <<<"$CLUSTERS_JSON" 2>/dev/null ||
    { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: ${1#.} isn't a string" >&2; return 1; }
}

cluster_secret() { secret_get ".credentials[\"$1\"].$2"; } # NAME KEY

# The install settings clusters.yaml holds, as KEY=VALUE lines, one for each
# key the file sets (an empty value too, so it wins over the environment):
# repositories.catalog is CATALOG_REPO_URL, repositories.library is
# LIBRARY_REVISION, and each options key is itself. true is 1, false and null
# are empty.
settings_lines() {
  # A value spread over lines would come out as more than one setting: refuse it.
  jq -r '
    def v: if . == true then "1" elif . == false or . == null then ""
      else tostring | if test("[\\n\\r]") then error("a setting'"'"'s value spans lines") else . end end;
    (if (.repositories // {}) | has("catalog") then "CATALOG_REPO_URL=\(.repositories.catalog | v)" else empty end),
    (if (.repositories // {}) | has("library") then "LIBRARY_REVISION=\(.repositories.library | v)" else empty end),
    ((.options // {}) | to_entries[] | "\(.key)=\(.value | v)")' <<<"$CLUSTERS_JSON" 2>/dev/null ||
    { echo "error: clusters.yaml: a setting's value spans lines" >&2; return 1; }
}

hub_name() { awk '$2 == "hub" {print $1}' <<<"$CLUSTERS_ROWS"; }
site_names() { awk '$2 != "hub" && NF {print $1}' <<<"$CLUSTERS_ROWS"; }

site_name() { # [NAME]
  local n=${1:-} all count
  all=$(site_names)
  if [ -n "$n" ]; then
    grep -qx -- "$n" <<<"$all" || { echo "error: $n isn't a site in clusters.yaml: $(echo $all | sed 's/ /, /g')" >&2; return 1; }
    echo "$n"; return 0
  fi
  count=$(grep -c . <<<"$all" || true)
  case "$count" in
    1) echo "$all" ;;
    0) echo "error: clusters.yaml has no site" >&2; return 1 ;;
    *) echo "error: name a site: $(echo $all | sed 's/ /, /g')" >&2; return 1 ;;
  esac
}

cluster_field() { # NAME role|location|api
  local col
  case "$2" in role) col=2 ;; location) col=3 ;; api) col=4 ;; *) echo "error: unknown field $2" >&2; return 1 ;; esac
  local v; v=$(awk -v n="$1" -v c="$col" '$1 == n {print $c}' <<<"$CLUSTERS_ROWS")
  [ -n "$v" ] || { echo "error: no cluster $1 in $CLUSTERS_DIR/clusters" >&2; return 1; }
  echo "$v"
}

cluster_kubeconfig() { cluster_field "$1" role >/dev/null && echo "$CLUSTERS_DIR/.config/$1/kubeconfig"; }

cluster_login_ok() { # NAME: exits non-zero, with the fix, when there's no working login
  local k; k=$(cluster_kubeconfig "$1") || return 1
  [ -f "$k" ] || { echo "error: no login for $1: run make login NAME=$1" >&2; return 1; }
  KUBECONFIG=$k oc whoami >/dev/null 2>&1 || { echo "error: $1: login expired: run make login NAME=$1" >&2; return 1; }
}

merge_kubeconfigs() { # HUB SITE OUT: renames each cluster, user and context, so equal names in the two files can't collide
  local out=$3 alias name tmp; tmp=$(mktemp -d); : > "$out"; chmod 600 "$out"
  for alias in hub site; do
    if [ "$alias" = hub ]; then name=$1; else name=$2; fi
    KUBECONFIG=$(cluster_kubeconfig "$name") oc config view --raw --flatten --minify -o json |
      jq --arg a "$alias" '.clusters[0].name = $a | .users[0].name = $a
        | .contexts[0].name = $a | .contexts[0].context.cluster = $a | .contexts[0].context.user = $a
        | .["current-context"] = $a' > "$tmp/$alias.json" || { rm -rf "$tmp"; return 1; }
  done
  KUBECONFIG="$tmp/hub.json:$tmp/site.json" oc config view --raw --flatten > "$out"
  rm -rf "$tmp"
}

# --- settings and secrets for every target --------------------------------
#
# deployment_load DIR: clusters_load, then make install's settings and the
# secret files, exported for this script and the ones it runs.
#
# Settings (settings_lines): a value the file holds, even an empty one, wins
# over the environment's; one it leaves out comes from the environment.
#
# Secrets: each becomes a file the scripts pass on by path, never a command line:
#   DEPLOYMENT_TOKEN_FILE   AI_GRID_DEPLOYMENT_TOKEN, else DEPLOYMENT_TOKEN_FILE,
#                           else github.deploymentToken, else .config/deployment-token
#   CATALOG_TOKEN_FILE      AI_GRID_CATALOG_TOKEN, else CATALOG_TOKEN_FILE, else
#                           github.catalogToken, else .config/catalog-token, else
#                           (page by page) ~/.ai-grid/catalog-token
#   QUAY_AUTH_FILE          AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD, else
#                           QUAY_AUTH_FILE, else quay:, else .config/quay-auth.json,
#                           else (page by page) ~/.config/containers/auth.json or
#                           $XDG_RUNTIME_DIR/containers/auth.json
# A value (from AI_GRID_* or the private file) is written to .config/generated/
# (mode 600, rewritten on every load, removed when the value goes). "Page by
# page" means no .config/clusters.yaml and no catalog setting. VAR_SOURCE says
# where each came from; secret_missing VAR prints the fix when there's none.
SETTINGS_KEYS_RE='CATALOG_REPO_URL|LIBRARY_REVISION'

deployment_load() { # DIR
  clusters_load "$1" || return 1
  settings_apply || return 1
  secrets_apply
}

settings_apply() {
  local lines line key value
  lines=$(settings_lines) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*} value=${line#*=}
    # Only a known setting becomes a variable, never PATH or the like.
    [[ "$key" =~ ^($SETTINGS_KEYS_RE|$SETTINGS_OPTIONS_RE)$ ]] ||
      { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: unknown setting $key" >&2; return 1; }
    printf -v "$key" '%s' "$value"; export "${key?}"
  done <<<"$lines"
  for key in $(compgen -v GATE_); do
    [[ "$key" != GATE_* || "${!key}" =~ ^[0-9]+$ ]] ||
      { echo "error: $key must be a number of seconds, not ${!key}" >&2; return 1; }
  done
}

clusters_private() { [ "$CLUSTERS_FILE" = "$CLUSTERS_DIR/.config/clusters.yaml" ]; }
page_by_page() { ! clusters_private && [ -z "${CATALOG_REPO_URL:-}" ]; }

_generated() { # NAME: writes stdin to .config/generated/NAME (mode 600) and prints its path
  local g="$CLUSTERS_DIR/.config/generated"
  ( umask 077; mkdir -p "$g"; cat > "$g/$1.new" ) && chmod 700 "$CLUSTERS_DIR/.config" "$g" &&
    chmod 600 "$g/$1.new" && mv -f "$g/$1.new" "$g/$1" && echo "$g/$1"
}

_abs() { case "$1" in /*) echo "$1" ;; "~/"*) echo "$HOME/${1#"~/"}" ;; *) echo "$CLUSTERS_DIR/$1" ;; esac; }

_secret_file() { # VAR ENV JQ_PATH NAME [HOME_DEFAULT]
  local var=$1 env=$2 path=$3 name=$4 home=${5:-} v="" f="" src=""
  v=${!env:-}; [ -z "$v" ] || src=$env
  if [ -z "$v" ] && [ -n "${!var:-}" ]; then
    f=$(_abs "${!var}") src=$var
    [ "$f" = "$CLUSTERS_DIR/.config/generated/$name" ] || rm -f "$CLUSTERS_DIR/.config/generated/$name"
  else
    if [ -z "$v" ]; then v=$(secret_get "$path") || return 1; [ -z "$v" ] || src="${path#.} in .config/clusters.yaml"; fi
    if [ -n "$v" ]; then
      f=$(printf '%s\n' "$v" | _generated "$name") || return 1
    else
      rm -f "$CLUSTERS_DIR/.config/generated/$name"
      if [ -s "$CLUSTERS_DIR/.config/$name" ]; then f="$CLUSTERS_DIR/.config/$name" src=".config/$name"
      elif [ -n "$home" ] && page_by_page && [ -s "$home" ]; then f=$home src=$home; fi
    fi
  fi
  printf -v "$var" '%s' "$f"; printf -v "${var}_SOURCE" '%s' "$src"; export "${var?}" "${var}_SOURCE"
}

_quay_auth() {
  local u p f="" src="" b64 h
  u=${AI_GRID_QUAY_USERNAME:-} p=${AI_GRID_QUAY_PASSWORD:-}
  [ -z "$u$p" ] || src="AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD"
  if [ -z "$u$p" ] && [ -n "${QUAY_AUTH_FILE:-${RHOAI_QUAY_AUTH_FILE:-}}" ]; then
    f=$(_abs "${QUAY_AUTH_FILE:-$RHOAI_QUAY_AUTH_FILE}") src=QUAY_AUTH_FILE
    [ "$f" = "$CLUSTERS_DIR/.config/generated/quay-auth.json" ] || rm -f "$CLUSTERS_DIR/.config/generated/quay-auth.json"
  else
    if [ -z "$u$p" ]; then
      u=$(secret_get .quay.username) && p=$(secret_get .quay.password) || return 1
      [ -z "$u$p" ] || src="quay: in .config/clusters.yaml"
    fi
    if [ -n "$u" ] && [ -n "$p" ]; then
      b64=$(printf '%s' "$u:$p" | base64 | tr -d '\n')
      f=$(printf '{"auths":{"quay.io/rhoai":{"auth":"%s"}}}\n' "$b64" | _generated quay-auth.json) || return 1
    elif [ -n "$u$p" ]; then
      echo "error: the quay.io/rhoai login needs both a username and a password ($src)" >&2; return 1
    else
      rm -f "$CLUSTERS_DIR/.config/generated/quay-auth.json"
      if [ -s "$CLUSTERS_DIR/.config/quay-auth.json" ]; then f="$CLUSTERS_DIR/.config/quay-auth.json" src=.config/quay-auth.json
      elif page_by_page; then
        for h in "$HOME/.config/containers/auth.json" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/containers/auth.json}"; do
          [ -n "$h" ] && [ -f "$h" ] && { f=$h src=$h; break; }
        done
      fi
    fi
  fi
  QUAY_AUTH_FILE=$f QUAY_AUTH_FILE_SOURCE=$src; export QUAY_AUTH_FILE QUAY_AUTH_FILE_SOURCE
}

secrets_apply() {
  _secret_file DEPLOYMENT_TOKEN_FILE AI_GRID_DEPLOYMENT_TOKEN .github.deploymentToken deployment-token || return 1
  _secret_file CATALOG_TOKEN_FILE AI_GRID_CATALOG_TOKEN .github.catalogToken catalog-token "$HOME/.ai-grid/catalog-token" || return 1
  _quay_auth
}

secret_missing() { # VAR: how to supply it
  case "$1:$(page_by_page && echo pp)" in
    DEPLOYMENT_TOKEN_FILE:*) echo "set github.deploymentToken in .config/clusters.yaml (make secrets NAME=github), or AI_GRID_DEPLOYMENT_TOKEN" ;;
    CATALOG_TOKEN_FILE:pp) echo "save it in ~/.ai-grid/catalog-token, or set CATALOG_TOKEN_FILE (install guide, page 2)" ;;
    CATALOG_TOKEN_FILE:*) echo "set github.catalogToken in .config/clusters.yaml (make secrets NAME=github), or AI_GRID_CATALOG_TOKEN" ;;
    QUAY_AUTH_FILE:pp) echo "set QUAY_AUTH_FILE to a container auth file with a quay.io/rhoai login" ;;
    QUAY_AUTH_FILE:*) echo "set quay.username and quay.password in .config/clusters.yaml (make secrets NAME=quay), or AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD" ;;
  esac
}

# scripts/clusters.sh --rows DIR prints one line per cluster (name role location
# api), or the error; prereqs.py uses it. scripts/clusters.sh --settings DIR
# prints settings_lines (install.sh and prereqs.py). scripts/clusters.sh --site [NAME]
# prints site_name's answer for this repository (the Makefile's SITE=), and
# scripts/clusters.sh --hub the hub's name.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --rows ]; then
  clusters_load "${2:-.}" && printf '%s' "$CLUSTERS_ROWS"
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --settings ]; then
  clusters_load "${2:-.}" && settings_lines
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --resolve ]; then
  # VAR=PATH<tab>SOURCE for each secret file (make prereqs); never a secret's value.
  deployment_load "${2:-.}" && for v in DEPLOYMENT_TOKEN_FILE CATALOG_TOKEN_FILE QUAY_AUTH_FILE; do
    s="${v}_SOURCE"; printf '%s=%s\t%s\n' "$v" "${!v}" "${!s}"; done
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --hub ]; then
  clusters_load "$(dirname "$0")/.." && hub_name
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --site ]; then
  clusters_load "$(dirname "$0")/.." && site_name "${2:-}"
fi
