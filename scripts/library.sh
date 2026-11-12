#!/usr/bin/env bash
# The library at the commit a deployment repository pins (libraryRevision and
# libraryRepoURL in root/kustomization.yaml).
#
#   scripts/library.sh [DEPLOYMENT_DIR]   fetch it and print its path
#   . scripts/library.sh; library_dir DIR sets $LIB, for the other scripts
#
# By default it's .library/ in the deployment repository (git-ignored), fetched
# on first use and moved when the pin changes. To use your own checkout instead,
# set LIBRARY to its path; it must already be at the pin.

library_dir() {
  local dir=${1:-.} k rev url
  k="$dir/root/kustomization.yaml"
  rev=$(sed -n -E 's/^[[:space:]]*libraryRevision:[[:space:]]*([^[:space:]#]+).*/\1/p' "$k" 2>/dev/null | head -n1)
  url=$(sed -n -E 's/^[[:space:]]*libraryRepoURL:[[:space:]]*([^[:space:]#]+).*/\1/p' "$k" 2>/dev/null | head -n1)
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no full libraryRevision in $k" >&2; return 1; }
  if [ -n "${LIBRARY:-}" ]; then
    LIB=$(cd "$LIBRARY" 2>/dev/null && pwd) || { echo "error: LIBRARY=$LIBRARY isn't a directory" >&2; return 1; }
    [ "$(git -C "$LIB" rev-parse HEAD 2>/dev/null)" = "$rev" ] ||
      { echo "error: LIBRARY=$LIBRARY isn't at your pin $rev: git -C $LIBRARY checkout $rev" >&2; return 1; }
    return 0
  fi
  [ -n "$url" ] || { echo "error: no libraryRepoURL in $k" >&2; return 1; }
  LIB="$(cd "$dir" && pwd)/.library"
  [ "$(git -C "$LIB" rev-parse HEAD 2>/dev/null)" = "$rev" ] && return 0
  echo "Fetching the library at $rev into .library/" >&2
  if [ ! -e "$LIB/.git" ]; then
    git init -q "$LIB" && git -C "$LIB" remote add origin "$url"
  else
    git -C "$LIB" remote set-url origin "$url"
  fi
  git -C "$LIB" fetch -q --depth 1 origin "$rev" && git -C "$LIB" checkout -q --detach FETCH_HEAD ||
    { echo "error: couldn't fetch $rev from $url" >&2; return 1; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  library_dir "${1:-$(cd "$(dirname "$0")/.." && pwd)}"
  echo "$LIB"
fi
