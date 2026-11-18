#!/usr/bin/env bash
# Check that the hub can read your deployment and catalog repositories with no
# login. The hub's Argo CD has no credential for either: it clones
# deploymentRepoURL (deployment-root and the root's own apps) and
# catalogRepoURL (the catalog's ApplicationSets) anonymously over https://.
# The provider console's catalog token reaches only the console's backend,
# which writes to the catalog; Argo CD never gets it. So both repositories must
# be public: a private one fails on the hub with "authentication required:
# Repository not found", after the install has already bootstrapped it.
#
# Each URL comes from root/inputs.env (make inputs writes it). Before that
# file names one, the deployment repository is this repository's origin, as
# make inputs would write it, and the catalog is CATALOG_REPO_URL (make prereqs
# passes clusters.yaml's catalog.url). An unset or REQUIRED- value is skipped.
#
# Each check is "git ls-remote --heads URL" with no login of yours: a clean
# environment (no credential helper, .netrc, git config, askpass or prompt;
# only PATH, and the proxy and CA variables, pass through), with no repository
# to read config from (GIT_DIR=/nonexistent, GIT_CEILING_DIRECTORIES), run from
# an empty directory, stopped after PUBLIC_REPO_TIMEOUT seconds (default 20).
# Your git config's http.proxy, http.sslCAInfo and http.sslCAPath, which are
# no login, pass through as -c options. Only https:// URLs with no login in
# them are accepted, because the hub has no SSH key and uses no login;
# set-inputs.sh writes an SSH origin as its https:// form.
#
# Prints one line per repository: status (ok, FAIL, WARN, skipped), name,
# detail; with --tsv, the three fields tab-separated (make prereqs reads that).
# A repository that is private or doesn't exist, or a URL the hub can't use,
# is a FAIL. So is a network error or timeout, unless --network-warn makes it
# a WARN: make install and make bootstrap go on then, and Argo CD's own sync
# shows a real problem later. Exits 1 when any check fails, else 0.
#
# Usage: scripts/check-public-repos.sh [--tsv] [--network-warn] [DEPLOYMENT_DIR]
set -euo pipefail
tsv="" network=FAIL
while [ $# -gt 0 ]; do
  case "$1" in
    --tsv) tsv=1; shift ;;
    --network-warn) network=WARN; shift ;;
    *) break ;;
  esac
done
[ $# -le 1 ] || { echo "usage: check-public-repos.sh [--tsv] [--network-warn] [DEPLOYMENT_DIR]" >&2; exit 2; }
dir=$(cd "${1:-$(dirname "$0")/..}" && pwd)
timeout=${PUBLIC_REPO_TIMEOUT:-20}
case "$timeout" in ''|*[!0-9]*|0) echo "error: PUBLIC_REPO_TIMEOUT is $timeout: a whole number of seconds" >&2; exit 2 ;; esac

failed=0
line() { # STATUS NAME DETAIL
  [ "$1" != FAIL ] || failed=1
  if [ -n "$tsv" ]; then printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  else printf '%-8s %-22s %s\n' "$1" "$2" "$3"; fi
}

inputs_value() { # NAME: its value in root/inputs.env, empty when unset
  [ -f "$dir/root/inputs.env" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$dir/root/inputs.env" | tail -n1 | tr -d '\r' | sed 's/[[:space:]]*$//'
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

# git with nothing of yours: no config, credential helper, askpass or prompt.
# Your git config's network settings, which carry no login: -c KEY=VALUE for each one set.
net_config=()
for key in http.proxy http.sslCAInfo http.sslCAPath; do
  case "$key" in http.proxy) type=() ;; *) type=(--type=path) ;; esac
  value=$(cd "$dir" && git config --get "${type[@]+"${type[@]}"}" "$key" 2>/dev/null) || continue
  [ -z "$value" ] || net_config+=(-c "$key=$value")
done

# git with nothing of yours: no config, credential helper, askpass or prompt.
anon_git() { # WORKDIR URL: git ls-remote --heads URL; stderr to WORKDIR/err
  local work=$1 url=$2 nope pid watch rc var pass=()
  nope=$(type -P false || echo /usr/bin/false)
  for var in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
      GIT_SSL_CAINFO GIT_SSL_CAPATH SSL_CERT_FILE SSL_CERT_DIR; do
    [ -z "${!var:-}" ] || pass+=("$var=${!var}")
  done
  ( cd "$work/home" && exec env -i PATH="$PATH" HOME="$work/home" XDG_CONFIG_HOME="$work/home" ${pass[@]+"${pass[@]}"} \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_DIR=/nonexistent GIT_CEILING_DIRECTORIES="$work" \
      GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$nope" SSH_ASKPASS="$nope" GCM_INTERACTIVE=never \
      git -c credential.helper= -c core.askPass="$nope" ${net_config[@]+"${net_config[@]}"} ls-remote --heads -- "$url" ) \
    >/dev/null 2>"$work/err" </dev/null & pid=$!
  # The watchdog kills its own sleep when it's stopped, so no sleep outlives it.
  ( s=""; trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$timeout" & s=$!; wait "$s"
    : > "$work/timed-out"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null & watch=$!
  wait "$pid" && rc=0 || rc=$?
  kill "$watch" 2>/dev/null || true
  wait "$watch" 2>/dev/null || true
  return "$rc"
}

check() { # NAME URL WHERE: WHERE is where the URL came from, for the fix
  local name=$1 url=$2 where=$3 work err repo host fix
  case "$url" in
    "") line skipped "$name" "no URL yet: run make inputs (page 2)"; return 0 ;;
    REQUIRED-*) line skipped "$name" "$where is still $url: run make inputs (page 2)"; return 0 ;;
    https://*@*) if [[ "$url" =~ ^https://[^/]*@ ]]; then  # never print the login
         line FAIL "$name" "$(sed -E 's#^https://[^/]*@#https://#' <<<"$url") ($where): remove the login from the URL: the hub reads it with no login"
         return 0
       fi ;;
    https://*) ;;
    *) line FAIL "$name" "$url ($where): the hub reads repositories over https:// with no login, and has no SSH key; set an https:// URL"
       return 0 ;;
  esac
  work=$(mktemp -d); mkdir "$work/home"
  if anon_git "$work" "$url"; then
    line ok "$name" "$url: readable with no login"
    rm -rf "$work"; return 0
  fi
  # git's own reason: its last fatal: line, else its last line.
  err=$({ grep '^fatal:' "$work/err" || grep -v '^[[:space:]]*$' "$work/err" || true; } | tail -n 1 | sed -E 's/^(fatal|error): //')
  host=${url#https://}; host=${host%%/*}
  repo=${url#https://"$host"/}; repo=${repo%.git}
  if [ -f "$work/timed-out" ]; then
    line "$network" "$name" "$url: no answer from $host in ${timeout}s; a network error, not a login one: check your network or proxy, then run this again"
  elif grep -qE 'returned error: 407' "$work/err"; then
    line "$network" "$name" "$url: your proxy wants a login ($err); a proxy error, not the repository's: check your proxy settings"
  elif grep -qE 'returned error: 429' "$work/err"; then
    line "$network" "$name" "$url: $host is limiting requests ($err); wait a few minutes, then run this again"
  elif grep -qiE 'repository not found|not found|could not read (username|password)|authentication (failed|required)|terminal prompts disabled|returned error: 40[134]|permission denied|access denied' "$work/err"; then
    if [ "$host" = github.com ]; then fix="make it public (gh repo edit $repo --visibility public --accept-visibility-change-consequences)"
    else fix="make it public on $host"; fi
    line FAIL "$name" "$url is private or doesn't exist: the hub reads this repository without a login: $fix; private repositories aren't supported ($err)"
  elif grep -qiE "could not resolve|failed to connect|couldn't connect|connection (refused|reset|timed out)|operation timed out|network is unreachable|no route to host|ssl|tls|certificate" "$work/err"; then
    line "$network" "$name" "$url: can't reach $host ($err); a network error, not a login one: check your network or proxy, then run this again"
  else
    line "$network" "$name" "$url: can't read it with no login (${err:-git ls-remote failed})"
  fi
  rm -rf "$work"
}

deployment=$(inputs_value deploymentRepoURL) where="deploymentRepoURL in root/inputs.env"
if [ -z "$deployment" ] && origin=$(git -C "$dir" remote get-url origin 2>/dev/null); then
  deployment=$(https_url "$origin") where="this repository's origin"
fi
check "deployment repository" "$deployment" "$where"
catalog=$(inputs_value catalogRepoURL) where="catalogRepoURL in root/inputs.env"
if [ -z "$catalog" ] && [ -n "${CATALOG_REPO_URL:-}" ]; then
  catalog=$(https_url "$CATALOG_REPO_URL") where="catalog.url"  # as make inputs would write it
fi
check "catalog repository" "$catalog" "$where"
exit "$failed"
