#!/usr/bin/env bash
# Copied from ai-grid-cluster-gitops apps/keycloak/base/manifests/scripts/render-realm.sh@60578f5
# (Apache-2.0), trimmed to this realm's placeholders, with a list placeholder added.
#
# Renders a realm import file from stdin to stdout, replacing each ${NAME}
# placeholder below with the environment variable NAME. A placeholder the file
# holds needs its variable set; one it doesn't hold needs nothing.
#
# TENANT_PORTAL_REDIRECT_URI is a list: URIs separated by spaces or commas
# (one per site). In the file it stands quoted inside a JSON array,
# "${TENANT_PORTAL_REDIRECT_URI}", and renders as one quoted string per URI.
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
    value=${!name}
    if [[ "$name" == TENANT_PORTAL_REDIRECT_URI ]]; then
      read -r -a uris <<<"${value//,/ }"
      if [[ ${#uris[@]} -eq 0 || "$value" == *[\"\\]* ]]; then
        echo "render-realm.sh: $name must list one or more URIs, separated by spaces or commas, with no quote or backslash" >&2
        exit 1
      fi
      value=$(printf '%s", "' "${uris[@]}")
      value=${value%'", "'}
    fi
    line=${line//"$placeholder"/"$value"}
  done
  printf '%s\n' "$line"
done
