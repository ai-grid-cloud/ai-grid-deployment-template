#!/usr/bin/env bash
# Put the install's secrets in .config/ (make secrets). Interactive: run it
# yourself, once, after you edit clusters.yaml. make install never prompts; it
# reads the files this writes.
#
#   scripts/secrets.sh           asks for each secret whose file doesn't exist
#   FORCE=1 scripts/secrets.sh   asks for every one again and replaces the files
#                                (only 1 counts); to replace one, delete its file
#
# It asks, in order, for:
#   .config/NAME/token           a token for each cluster in clusters.yaml, such
#                                as the output of oc whoami -t (make login reads it)
#   .config/deployment-token     a token that can push to this repository
#   .config/catalog-token        a token that can write your catalog repository
#   .config/quay-auth.json       your quay.io/rhoai login: it runs
#                                podman login --authfile .config/quay-auth.json quay.io/rhoai
#                                which asks for the user name and password itself;
#                                it needs a terminal, so CI supplies the file instead
#
# A token is read with the terminal's echo off and written by shell builtins, so
# it never appears on the screen, in a command line or in the output. Each file
# is mode 600 and .config/ is mode 700. An empty answer skips that file. CI
# supplies the same files, or the variables AI_GRID_TOKEN_<NAME>, instead.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
cfg="$CLUSTERS_DIR/.config"
force=""; [ "${FORCE:-}" != 1 ] || force=1
( umask 077; mkdir -p "$cfg" ); chmod 700 "$cfg"

ask() { # FILE WHAT: reads one secret with echo off and writes it to FILE (mode 600)
  local file=$1 what=$2 secret=""
  if [ -s "$file" ] && [ -z "$force" ]; then
    echo "${file#"$CLUSTERS_DIR/"}: exists, kept (FORCE=1 replaces it)."
    return 0
  fi
  IFS= read -r -s -p "$what (empty skips): " secret || true
  echo
  # Drop leading and trailing whitespace, such as a pasted line ending.
  secret=${secret#"${secret%%[![:space:]]*}"}; secret=${secret%"${secret##*[![:space:]]}"}
  if [ -z "$secret" ]; then echo "${file#"$CLUSTERS_DIR/"}: skipped."; return 0; fi
  ( umask 077; mkdir -p "$(dirname "$file")"; printf '%s\n' "$secret" > "$file.new" )
  chmod 700 "$(dirname "$file")"; chmod 600 "$file.new"; mv -f "$file.new" "$file"
  echo "${file#"$CLUSTERS_DIR/"}: written."
}

for name in $(hub_name) $(site_names); do
  ask "$cfg/$name/token" "Token for $name ($(cluster_field "$name" api); oc whoami -t)"
done
ask "$cfg/deployment-token" "Token that can push to this deployment repository"
ask "$cfg/catalog-token" "Token that can write the catalog repository"

auth="$cfg/quay-auth.json"
if [ -s "$auth" ] && [ -z "$force" ]; then
  echo ".config/quay-auth.json: exists, kept (FORCE=1 replaces it)."
else
  echo "Log in to quay.io/rhoai (podman asks for the user name and password):"
  # Into a new file first, so a failed login keeps the old one.
  rm -f "$auth.new"
  ( umask 077; podman login --authfile "$auth.new" quay.io/rhoai ) ||
    { rm -f "$auth.new"; echo "error: podman login failed; run make secrets again" >&2; exit 1; }
  chmod 600 "$auth.new"; mv -f "$auth.new" "$auth"
fi
echo "Next: make login NONINTERACTIVE=1, then make prereqs."
