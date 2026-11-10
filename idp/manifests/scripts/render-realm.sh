#!/usr/bin/env bash
# Copied from ai-grid-cluster-gitops apps/keycloak/base/manifests/scripts/render-realm.sh@60578f5
# (Apache-2.0), trimmed to this realm's placeholders.
#
# Renders a realm import file from stdin to stdout, replacing each ${NAME}
# placeholder below with the environment variable NAME. A placeholder the file
# holds needs its variable set; one it doesn't hold needs nothing.
set -Eeuo pipefail

placeholders=(
  KEYCLOAK_CLIENT_SECRET
  TENANT_PORTAL_REDIRECT_URI
)

while IFS= read -r line || [[ -n "$line" ]]; do
  for name in "${placeholders[@]}"; do
    placeholder="\${$name}"
    [[ "$line" == *"$placeholder"* ]] || continue
    if [[ -z "${!name+set}" ]]; then
      echo "render-realm.sh: the file holds $placeholder, but $name is not set" >&2
      exit 1
    fi
    line=${line//"$placeholder"/"${!name}"}
  done
  printf '%s\n' "$line"
done
