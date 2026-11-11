#!/usr/bin/env bash
# Check that the tools this install guide uses are on your PATH.
# Usage: scripts/check-tools.sh
# Prints one line per tool and exits non-zero if any is missing or too old.
set -uo pipefail

missing=0
check() { # name, what it's for
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok       %-11s %s\n' "$1" "$2"
  else
    printf 'MISSING  %-11s %s\n' "$1" "$2"
    missing=1
  fi
}

check oc         "OpenShift CLI, on every page"
check kubectl    "the console secrets script (page 4)"
check kustomize  "renders your root (pages 2 and 3)"
check git        "clones and pushes your repositories"
check jq         "reads JSON in the console and tenant scripts (pages 4 and 7)"
check curl       "calls the console, Keycloak and the MaaS gateway (pages 6 and 7)"
check openssl    "generates passwords (pages 3, 4 and 7)"
check base64     "encodes secrets (pages 3, 4 and 7)"
check python3    "reads cluster state in the admin and revision scripts (page 3)"
check htpasswd   "creates the break-glass admin login (pages 3 and 5)"
check clusteradm "imports the site into ACM (page 5)"

if command -v kustomize >/dev/null 2>&1; then
  v=$(kustomize version 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9][0-9]*\)\..*/\1/p' | head -1)
  if [ -n "$v" ] && [ "$v" -lt 5 ]; then
    printf 'OLD      %-11s %s\n' kustomize "version 5 or later needed, found $(kustomize version)"
    missing=1
  fi
fi

if [ "$missing" -ne 0 ]; then
  echo "Install the tools marked MISSING or OLD, then run this again."
  exit 1
fi
echo "All tools found."
