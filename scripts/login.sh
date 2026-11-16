#!/usr/bin/env bash
# Log in to the clusters in clusters.yaml, each into .config/NAME/kubeconfig.
#
#   scripts/login.sh                         (make login) every cluster whose login doesn't work
#   scripts/login.sh NAME                    (make login NAME=...) one cluster; NAME=site is the only site
#   scripts/login.sh NAME [oc login flags]   oc login to NAME with those flags, as given
#
#   scripts/login.sh --non-interactive [NAME]   (make install) the same, never opening a browser
#
# Each cluster logs in with its stored credentials, in the order below. Only a
# cluster with none of them gets oc login --web, which opens your browser;
# --non-interactive stops there instead, with exit 1. To use a kubeconfig you
# already have, such as the installer's auth/kubeconfig, copy it to
# .config/NAME/kubeconfig or name it in credentials.NAME.kubeconfig.
#
# For each cluster it uses the first of these that logs in:
#   1. a working .config/NAME/kubeconfig, kept as it is;
#   2. credentials.NAME.kubeconfig in .config/clusters.yaml: a kubeconfig's
#      path (relative to this repository), copied to .config/NAME/kubeconfig;
#   3. a token: the environment variable AI_GRID_TOKEN_<NAME> (NAME upper-cased,
#      - turned into _), else credentials.NAME.token, else the older file
#      .config/NAME/token;
#   4. a username and password: AI_GRID_USERNAME_<NAME> and
#      AI_GRID_PASSWORD_<NAME>, else credentials.NAME.username and .password.
#      It gets a fresh token from the cluster's OAuth server as oc login does
#      (the openshift-challenging-client, with X-CSRF-Token: 1), so a saved
#      password logs in again after a token expires.
# The environment wins over the file. A token that doesn't log in (expired)
# falls through to the password; a certificate problem stops, since a password
# wouldn't help. A token, from 3 or 4, is written into .config/NAME/kubeconfig
# (mode 600) with the API URL from clusters.yaml. The cluster's certificate,
# and the OAuth server's, are checked against the system's CA trust, or against
# .config/NAME/ca.crt when that file exists. Tokens and passwords are read and
# written by shell builtins only, and the password reaches curl on its standard
# input (curl -K -), so neither appears in a command line or in the output.
# When stored credentials fail, it stops for that cluster with exit 1 (no
# browser). With none stored, --non-interactive stops with exit 1 and says where
# to put one: credentials.NAME in .config/clusters.yaml (make secrets).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."

login() { # NAME [oc login flags]
  local name=$1 api k; shift
  api=$(cluster_field "$name" api) || return 1
  k=$(cluster_kubeconfig "$name")
  mkdir -p "$(dirname "$k")"; chmod 700 "$(dirname "$k")"
  [ $# -gt 0 ] || set -- --web
  echo "Logging in to $name ($api)."
  KUBECONFIG=$k oc login --server "$api" "$@" || return 1
  chmod 600 "$k"
  echo "Logged in to $name as $(KUBECONFIG=$k oc whoami)."
}

trim() { # VAR: drops the value's leading and trailing whitespace, such as a Windows line ending's \r
  local v=${!1}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf -v "$1" '%s' "$v"
}

upper() { tr 'a-z-' 'A-Z_' <<<"$1"; } # NAME: as it appears in a variable's name

kubeconfig_login() { # NAME: copies credentials.NAME.kubeconfig when it logs in; 1 when it's unset or doesn't, 2 to stop
  local name=$1 p k err
  p=$(cluster_secret "$name" kubeconfig) || return 2
  [ -n "$p" ] || return 1
  tried=1
  # shellcheck disable=SC2088 # a literal ~/ at the path's start means the home directory
  case "$p" in /*) ;; "~/"*) p="$HOME/${p#"~/"}" ;; *) p="$CLUSTERS_DIR/$p" ;; esac
  [ -f "$p" ] || { echo "$name: credentials.$name.kubeconfig names no file ($p); trying the next credential." >&2; return 1; }
  if ! err=$(KUBECONFIG=$p oc whoami 2>&1 >/dev/null); then
    echo "$name: the kubeconfig $p doesn't log in (${err%%$'\n'*}); trying the next credential." >&2
    return 1
  fi
  k=$(cluster_kubeconfig "$name"); mkdir -p "$(dirname "$k")"; chmod 700 "$(dirname "$k")"
  # Flattened, so certificate paths relative to the original keep working.
  rm -f "$k.new"; ( umask 077; KUBECONFIG=$p oc config view --raw --flatten > "$k.new" ) || { rm -f "$k.new"; return 2; }
  chmod 600 "$k.new"; mv -f "$k.new" "$k"
  echo "Logged in to $name as $(KUBECONFIG=$k oc whoami), with the kubeconfig $p."
}

token_source() { # NAME: sets token and src; 1 when there's no token, 2 to stop
  local name=$1 var tf v
  var=AI_GRID_TOKEN_$(upper "$name"); tf="$(dirname "$(cluster_kubeconfig "$name")")/token"
  token="" src=""
  v=$(cluster_secret "$name" token) || return 2
  if [ -n "${!var:-}" ]; then token=${!var}; src=$var
  elif [ -n "$v" ]; then token=$v; src="credentials.$name.token in .config/clusters.yaml"
  elif [ -f "$tf" ]; then IFS= read -r token < "$tf" || true; src=${tf#"$CLUSTERS_DIR/"}
  else return 1; fi
  trim token
}

password_source() { # NAME: sets user, pass and src; 1 when there's no password, 2 to stop
  local name=$1 uv pv
  uv=AI_GRID_USERNAME_$(upper "$name"); pv=AI_GRID_PASSWORD_$(upper "$name")
  user="" pass="" src=""
  if [ -n "${!uv:-}" ] || [ -n "${!pv:-}" ]; then
    user=${!uv:-} pass=${!pv:-} src=$pv
    [ -n "$user" ] && [ -n "$pass" ] || { echo "error: $name: set both $uv and $pv" >&2; return 2; }
  else
    user=$(cluster_secret "$name" username) || return 2
    pass=$(cluster_secret "$name" password) || return 2
    [ -n "$user$pass" ] || return 1
    src="credentials.$name.password in .config/clusters.yaml"
    [ -n "$user" ] || { echo "error: $name: credentials.$name.password needs credentials.$name.username in .config/clusters.yaml" >&2; return 2; }
    [ -n "$pass" ] || { echo "error: $name: credentials.$name.username needs credentials.$name.password in .config/clusters.yaml" >&2; return 2; }
  fi
  trim user; pass=${pass%$'\r'}
  [[ "$user$pass" != *[$'\n\r']* ]] || { echo "error: $name: the username or password in $src has a line break" >&2; return 2; }
}

certificate_or() { # NAME ERR WHAT: says certificate problem when ERR is one, else WHAT
  if [[ "$2" =~ certificate|SSL ]]; then
    echo "error: $1: a certificate problem with its OAuth server: put a CA that trusts it in $(dirname "$(cluster_kubeconfig "$1")")/ca.crt or fix the trust: ${2%%$'\n'*}" >&2
  else echo "error: $1: $3: ${2%%$'\n'*}" >&2; fi
}

oauth_token() { # NAME: sets token from the cluster's OAuth server for $user and $pass (oc login's challenge flow)
  local name=$1 api dir cacert=() endpoint hdrs status cred
  api=$(cluster_field "$name" api); dir=$(dirname "$(cluster_kubeconfig "$name")")
  [ ! -f "$dir/ca.crt" ] || cacert=(--cacert "$dir/ca.crt")
  if ! endpoint=$(curl -sS --max-time 20 ${cacert[@]+"${cacert[@]}"} "$api/.well-known/oauth-authorization-server" 2>&1); then
    certificate_or "$name" "$endpoint" "can't reach $api's OAuth discovery"; return 1
  fi
  endpoint=$(jq -r '.authorization_endpoint // empty' <<<"$endpoint" 2>/dev/null || true)
  [[ "$endpoint" =~ ^https:// ]] || { echo "error: $name: $api names no OAuth authorization endpoint" >&2; return 1; }
  # curl's config syntax: a double-quoted value, with \ and " escaped. printf is
  # a builtin, so the password goes to curl's stdin without a command line.
  cred="$user:$pass"; cred=${cred//\\/\\\\}; cred=${cred//\"/\\\"}
  if ! hdrs=$(printf 'user = "%s"\n' "$cred" | curl -sS --max-time 20 ${cacert[@]+"${cacert[@]}"} -K - -H 'X-CSRF-Token: 1' \
      -o /dev/null -D - "$endpoint?response_type=token&client_id=openshift-challenging-client" 2>&1); then
    certificate_or "$name" "$hdrs" "can't reach the OAuth server"; return 1
  fi
  status=$(head -n 1 <<<"$hdrs" | tr -d '\r')
  token=$(tr -d '\r' <<<"$hdrs" | sed -n 's/^[Ll]ocation:.*[#&]access_token=\([^&]*\).*$/\1/p' | head -n 1)
  if [ -z "$token" ]; then
    echo "error: $name: the OAuth server refused $user (${status#HTTP/* }): check the username and password in $src" >&2
    return 1
  fi
  printf -v token '%b' "${token//%/\\x}"   # the fragment is URL-encoded, such as %7E for ~
}

write_kubeconfig() { # NAME: writes NAME's kubeconfig from $token, then checks it; names $src on failure.
  # 1 when the token doesn't log in, 2 on a certificate problem.
  local name=$1 api k dir tmp ca="" err
  api=$(cluster_field "$name" api) || return 2
  k=$(cluster_kubeconfig "$name"); dir=$(dirname "$k")
  [ -n "$token" ] || { echo "error: $name: $src is empty: put the cluster's token in it" >&2; return 1; }
  # A token is one word of these characters (OpenShift sha256~ tokens and JWTs
  # are); anything else could break the YAML, so stop without printing it.
  [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] ||
    { echo "error: $name: the token from $src isn't a single word; check it" >&2; return 1; }
  mkdir -p "$dir"; chmod 700 "$dir"
  tmp="$k.new"; rm -f "$tmp"
  [ ! -f "$dir/ca.crt" ] || ca="    certificate-authority: $dir/ca.crt"$'\n'
  # The token is single-quoted so YAML reads it as a string; it can't hold a quote.
  ( umask 077; printf "apiVersion: v1\nkind: Config\nclusters:\n- name: %s\n  cluster:\n    server: %s\n%scontexts:\n- name: %s\n  context:\n    cluster: %s\n    user: %s\ncurrent-context: %s\nusers:\n- name: %s\n  user:\n    token: '%s'\n" \
      "$name" "$api" "$ca" "$name" "$name" "$name" "$name" "$name" "$token" > "$tmp" )
  chmod 600 "$tmp"
  # Only stderr is kept, so err never holds the token.
  if ! err=$(KUBECONFIG=$tmp oc whoami 2>&1 >/dev/null); then
    rm -f "$tmp"
    if [[ "$err" =~ x509|certificate|"unknown authority" ]]; then
      echo "error: $name: a certificate problem with $api, not the token: put the API's CA in $dir/ca.crt or fix the cluster's trust: ${err%%$'\n'*}" >&2
      return 2
    fi
    echo "error: $name: the token from $src doesn't log in to $api: replace it" >&2
    return 1
  fi
  mv -f "$tmp" "$k"
  echo "Logged in to $name as $(KUBECONFIG=$k oc whoami)."
}

token_login() { # NAME: the first credential that logs in (see the header); writes NAME's kubeconfig
  local name=$1 token src user pass rc tried="" tv uv
  tv=AI_GRID_TOKEN_$(upper "$name") uv=AI_GRID_USERNAME_$(upper "$name")
  # The environment wins over the file: with AI_GRID_ credentials set, skip the file's kubeconfig.
  if [ -z "${!tv:-}${!uv:-}" ]; then
    kubeconfig_login "$name" && return 0 || rc=$?
    [ "$rc" = 1 ] || return 1
  fi
  token_source "$name" && rc=0 || rc=$?
  [ "$rc" != 2 ] || return 1
  if [ "$rc" = 0 ]; then
    tried=1
    write_kubeconfig "$name" && return 0 || rc=$?
    [ "$rc" = 1 ] || return 1     # a certificate problem: a password wouldn't help
  fi
  password_source "$name" && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    2) return 1 ;;
    *) [ -n "$tried" ] && return 1
       return 3 ;;     # nothing stored: the caller says so, or opens the browser
  esac
  echo "$name: logging in as $user with $src."
  oauth_token "$name" || return 1
  src="the OAuth server's token for $user"
  write_kubeconfig "$name"
}

none_stored() { # NAME
  echo "error: $1: no working login and nothing to log in with: set credentials.$1 in .config/clusters.yaml (make secrets), or AI_GRID_TOKEN_$(upper "$1"); credentials.$1 takes a token, a username and password, or a kubeconfig path" >&2
}

# NAME with oc login flags: oc login with them, as you asked.
if [ "${1:-}" != --non-interactive ] && [ $# -ge 2 ]; then
  name=$1; shift
  login "$name" "$@"; exit
fi
web=1
if [ "${1:-}" = --non-interactive ]; then web=""; shift; fi
if [ $# -ge 1 ]; then names=$1; else names="$(hub_name) $(site_names)"; fi
rc=0
for name in $names; do
  if cluster_login_ok "$name" 2>/dev/null; then echo "$name: already logged in."; continue; fi
  token_login "$name" && r=0 || r=$?
  case "$r" in
    0) ;;
    3) if [ -n "$web" ]; then login "$name" || rc=1; else none_stored "$name"; rc=1; fi ;;
    *) rc=1 ;;
  esac
done
exit "$rc"
