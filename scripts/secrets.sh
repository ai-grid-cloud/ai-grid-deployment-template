#!/usr/bin/env bash
# Put the install's secrets in .config/clusters.yaml (make secrets).
# Interactive: run it yourself, once, after you edit the clusters in it. make
# install never prompts; it reads what this writes.
#
#   scripts/secrets.sh           asks for each secret the file doesn't hold yet
#   FORCE=1 scripts/secrets.sh   asks for every one again (only 1 counts); an
#                                answer replaces the value, an empty one keeps it
#   scripts/secrets.sh NAME      asks only for NAME's secrets and replaces them,
#                                whatever is stored (make secrets NAME=NAME): a
#                                cluster's name (its token, or username and
#                                password), github (both tokens) or quay (the
#                                robot account); everything else is kept
#
# .config/clusters.yaml is private: git ignores .config/, the file is mode 600
# and .config/ is mode 700. When only the committed clusters.yaml exists, this
# copies it there first, and from then on the scripts read the private copy.
#
# It asks, in order, for:
#   credentials.NAME   each cluster's login, hub first: a token (oc whoami -t),
#                      or, when you leave the token empty, a username and a
#                      password. A cluster that has a kubeconfig: is kept as is.
#   github.deploymentToken   a token that can push to this repository
#   github.catalogToken      a token that can write your catalog repository
#   quay.username, quay.password   the quay.io/rhoai robot account
#
# It keeps the rest of the file as you wrote it, and rewrites the credentials:,
# github: and quay: blocks as one block at the end. A secret is read with the
# terminal's echo off and written by shell builtins, so it never appears on the
# screen, in a command line or in the output. An empty answer skips that value.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
root="$(cd "$here/.." && pwd)"
cfg="$root/.config" file="$root/.config/clusters.yaml"
force=""; [ "${FORCE:-}" != 1 ] || force=1
MARK='# Secrets (make secrets writes this part; you can edit it).'

if [ ! -f "$file" ]; then
  if [ ! -f "$root/clusters.yaml" ]; then
    # A first run: start the private file from the example, for you to fill in.
    ( umask 077; mkdir -p "$cfg"; cp "$root/clusters-example.yaml" "$file" )
    chmod 700 "$cfg"; chmod 600 "$file"
    echo "Created .config/clusters.yaml from clusters-example.yaml: edit it, then run make secrets again." >&2
    exit 1
  fi
  ( umask 077; mkdir -p "$cfg"; cp "$root/clusters.yaml" "$file" )
  chmod 700 "$cfg"; chmod 600 "$file"
  echo "Copied clusters.yaml to .config/clusters.yaml: the scripts read .config/clusters.yaml from now on, so edit that one."
fi
chmod 700 "$cfg"
clusters_load "$root"
target=${1:-}
if [ -n "$target" ]; then
  case " github quay $(hub_name) $(site_names | tr '\n' ' ')" in
    *" $target "*) ;;
    *) echo "error: NAME=$target isn't one of: $(hub_name) $(site_names | tr '\n' ' ')github quay" >&2; exit 1 ;;
  esac
fi

trim() { # VAR: drops leading and trailing whitespace, such as a pasted line ending
  local v=${!1}
  v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  printf -v "$1" '%s' "$v"
}
ask() { # VAR PROMPT hidden|visible: reads one answer into VAR
  local _a=""
  if [ "$3" = hidden ]; then IFS= read -r -s -p "$2: " _a || true; echo >&2
  else IFS= read -r -p "$2: " _a || true; fi
  _a=${_a%$'\r'}
  printf -v "$1" '%s' "$_a"
}
quote() { # VAR OUT WHAT: VAR's value as a double-quoted YAML (JSON-style) string in OUT
  local _v=${!1} _q="" _c _i _hex
  case "$_v" in *$'\n'*) echo "error: $3: a value can't span lines; .config/clusters.yaml is unchanged" >&2; return 1 ;; esac
  _v=${_v//\\/\\\\}; _v=${_v//\"/\\\"}
  if [[ "$_v" == *[[:cntrl:]]* ]]; then
    local LC_ALL=C
    for ((_i = 0; _i < ${#_v}; _i++)); do
      _c=${_v:_i:1}
      case "$_c" in
        $'\t') _q+='\t' ;; $'\r') _q+='\r' ;;
        [[:cntrl:]]) printf -v _hex '%04x' "'$_c"; _q+="\\u$_hex" ;;
        *) _q+=$_c ;;
      esac
    done
    _v=$_q
  fi
  printf -v "$2" '"%s"' "$_v"
}

# Clusters: c_NAMES, and per index the kept or new token, username, password, kubeconfig.
names=() c_tok=() c_user=() c_pw=() c_kc=()
for name in $(hub_name) $(site_names); do
  i=${#names[@]}; names+=("$name")
  c_tok[i]=$(cluster_secret "$name" token); c_user[i]=$(cluster_secret "$name" username)
  c_pw[i]=$(cluster_secret "$name" password); c_kc[i]=$(cluster_secret "$name" kubeconfig)
  if [ -n "$target" ]; then [ "$target" = "$name" ] || continue
  elif [ -n "${c_kc[i]}" ]; then echo "credentials.$name: a kubeconfig, kept."; continue
  elif [ -z "$force" ] && { [ -n "${c_tok[i]}" ] || { [ -n "${c_user[i]}" ] && [ -n "${c_pw[i]}" ]; }; }; then
    echo "credentials.$name: kept (FORCE=1 replaces it)."; continue
  fi
  ask tok "Token for $name ($(cluster_field "$name" api); oc whoami -t; empty to use a username and password)" hidden
  trim tok
  if [ -n "$tok" ]; then
    c_tok[i]=$tok c_user[i]="" c_pw[i]="" c_kc[i]=""; echo "credentials.$name: token set."; continue
  fi
  ask user "Username for $name (empty skips)" visible; trim user
  [ -n "$user" ] || { echo "credentials.$name: skipped."; continue; }
  ask pw "Password for $user on $name" hidden
  [ -n "$pw" ] || { echo "credentials.$name: no password, skipped."; continue; }
  c_tok[i]="" c_user[i]=$user c_pw[i]=$pw c_kc[i]=""; echo "credentials.$name: username and password set."
done

one() { # VAR JQ_PATH PROMPT hidden|visible: keeps VAR's current value or asks for it
  local _v _g=${2#.}; _g=${_g%%.*}; _v=$(secret_get "$2")
  if [ -n "$target" ] && [ "$target" != "$_g" ]; then :
  elif [ -n "$_v" ] && [ -z "$force" ] && [ -z "$target" ]; then echo "${2#.}: kept (FORCE=1 replaces it)."
  else
    local _n; ask _n "$3 (empty skips)" "$4"
    [ "$4" = hidden ] && [[ "$2" == *password ]] || trim _n
    if [ -n "$_n" ]; then _v=$_n; echo "${2#.}: set."; else echo "${2#.}: skipped."; fi
  fi
  printf -v "$1" '%s' "$_v"
}
one gh_deploy .github.deploymentToken "Token that can push to this deployment repository" hidden
one gh_catalog .github.catalogToken "Token that can write the catalog repository" hidden
one quay_user .quay.username "The quay.io/rhoai robot account's username" visible
one quay_pw .quay.password "The quay.io/rhoai robot account's password" hidden

# The new file: the user's text without the secret blocks, then one secret block.
tmpd=$(umask 077; mktemp -d "$cfg/.secrets.XXXXXX")
trap 'rm -rf "$tmpd"' EXIT
mkdir -m 700 "$tmpd/.config"
new="$tmpd/.config/clusters.yaml"
# A top-level key line starts with neither a space, a # nor a -; the blocks run
# to the next one. Comment and blank lines at column 0 inside a block are held
# back, and kept when the next key is kept: they most likely describe it.
( umask 077
  awk -v mark="$MARK" '
    $0 == mark { next }
    /^[^ \t#-]/ && !/^\.\.\.|^---/ {
      if ($0 ~ /^(credentials|github|quay)[ \t]*:/) { drop = 1; held = ""; next }
      if (drop) { printf "%s", held; held = ""; drop = 0 }
    }
    drop { if ($0 ~ /^(#|[ \t]*$)/) held = held $0 "\n"; next }
    { print }' "$file" > "$new.body" )
{
  # Drop trailing blank lines, then a blank line and the block.
  body=$(<"$new.body"); while [[ "$body" == *$'\n' ]]; do body=${body%$'\n'}; done
  printf '%s\n\n%s\n' "$body" "$MARK"
  any=""
  for i in "${!names[@]}"; do
    [ -n "${c_tok[i]}${c_user[i]}${c_pw[i]}${c_kc[i]}" ] || continue
    [ -n "$any" ] || printf 'credentials:\n'; any=1
    printf '  "%s":\n' "${names[i]}"
    for k in token user pw kc; do
      case $k in token) var="c_tok[$i]" key=token ;; user) var="c_user[$i]" key=username ;;
        pw) var="c_pw[$i]" key=password ;; kc) var="c_kc[$i]" key=kubeconfig ;; esac
      [ -n "${!var}" ] || continue
      quote "$var" q "credentials.${names[i]}.$key" || exit 1; printf '    %s: %s\n' "$key" "$q"
    done
  done
  [ -n "$any" ] || printf 'credentials: {}\n'
  printf 'github:\n'; any=""
  [ -z "$gh_deploy" ] || { quote gh_deploy q github.deploymentToken || exit 1; printf '  deploymentToken: %s\n' "$q"; any=1; }
  [ -z "$gh_catalog" ] || { quote gh_catalog q github.catalogToken || exit 1; printf '  catalogToken: %s\n' "$q"; any=1; }
  [ -n "$any" ] || printf '  {}\n'
  printf 'quay:\n'; any=""
  [ -z "$quay_user" ] || { quote quay_user q quay.username || exit 1; printf '  username: %s\n' "$q"; any=1; }
  [ -z "$quay_pw" ] || { quote quay_pw q quay.password || exit 1; printf '  password: %s\n' "$q"; any=1; }
  [ -n "$any" ] || printf '  {}\n'
} > "$new.next"
rm -f "$new.body"; mv -f "$new.next" "$new"; chmod 600 "$new"
# Check the new file reads back before it replaces the old one.
( clusters_load "$tmpd" >/dev/null ) ||
  { echo "error: the new file didn't load; .config/clusters.yaml is unchanged" >&2; exit 1; }
mv -f "$new" "$file"; chmod 600 "$file"
echo "Wrote .config/clusters.yaml."
echo "Next: make login, then make prereqs."
