#!/usr/bin/env bash
# The library at the revision a deployment repository names (libraryRevision
# and libraryRepoURL in root/applicationset.yaml): a branch, such as main, which
# the hub follows, or a full commit SHA, which pins it.
#
#   scripts/library.sh [DEPLOYMENT_DIR]   fetch it and print its path
#   . scripts/library.sh; library_dir DIR sets $LIB, for the other scripts
#
# By default it's .library/ in the deployment repository (git-ignored). For a
# pinned commit, it's fetched on first use and moved when the pin changes. For a
# branch, it's fetched on every use, so it's at the commit the branch is at now,
# as the hub is once Argo CD has synced. To use your own checkout instead, set
# LIBRARY to its path; it must already be at the pin, or for a branch at that
# branch's tip as your checkout knows it (git pull it first): LIBRARY is never
# fetched.

# library_pin DIR NAME: prints libraryRevision or libraryRepoURL from DIR's
# root/applicationset.yaml, the one place each is set (a YAML anchor on the
# value, such as libraryRevision: &libraryRevision main, is skipped).
library_pin() {
  sed -n -E "s/^[[:space:]]*$2:[[:space:]]*(&[A-Za-z]+[[:space:]]+)?([^[:space:]#*&]+).*/\\2/p" \
    "$1/root/applicationset.yaml" 2>/dev/null | head -n1
}

# library_is_sha REV: whether REV is a full commit SHA (a pin), not a branch.
library_is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# library_at CHECKOUT REV: whether CHECKOUT is at REV: that commit, or for a
# branch, the commit its origin/REV (as library_dir fetches it) or local REV is.
library_at() {
  local head r
  head=$(git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
  if library_is_sha "$2"; then [ "$head" = "$2" ]; return; fi
  for r in "refs/remotes/origin/$2" "refs/heads/$2"; do
    [ "$(git -C "$1" rev-parse -q --verify "$r^{commit}" 2>/dev/null)" = "$head" ] && return 0
  done
  return 1
}

library_dir() {
  local dir=${1:-.} k rev url new reason
  k="$dir/root/applicationset.yaml"
  rev=$(library_pin "$dir" libraryRevision)
  url=$(library_pin "$dir" libraryRepoURL)
  [ -n "$rev" ] || { echo "error: no libraryRevision in $k" >&2; return 1; }
  if [ -n "${LIBRARY:-}" ]; then
    LIB=$(cd "$LIBRARY" 2>/dev/null && pwd) || { echo "error: LIBRARY=$LIBRARY isn't a directory" >&2; return 1; }
    library_at "$LIB" "$rev" && return 0
    if library_is_sha "$rev"; then
      echo "error: LIBRARY=$LIBRARY isn't at your pin $rev: git -C $LIBRARY checkout $rev" >&2
    else
      echo "error: LIBRARY=$LIBRARY isn't at the tip of $rev, the branch you follow: git -C $LIBRARY checkout $rev && git -C $LIBRARY pull" >&2
    fi
    return 1
  fi
  [ -n "$url" ] || { echo "error: no libraryRepoURL in $k" >&2; return 1; }
  LIB="$(cd "$dir" && pwd)/.library"
  if library_is_sha "$rev" && [ "$(git -C "$LIB" rev-parse HEAD 2>/dev/null)" = "$rev" ]; then return 0; fi
  if [ ! -e "$LIB/.git" ]; then
    git init -q "$LIB" && git -C "$LIB" remote add origin "$url"
  else
    git -C "$LIB" remote set-url origin "$url"
  fi
  if library_is_sha "$rev"; then
    echo "Fetching the library at $rev into .library/" >&2
    git -C "$LIB" fetch -q --depth 1 origin "$rev" && git -C "$LIB" checkout -q --detach FETCH_HEAD ||
      { echo "error: couldn't fetch $rev from $url" >&2; return 1; }
    return 0
  fi
  # A branch: its tip now, kept as origin/BRANCH for library_at. When the
  # library can't be reached, the branch as last fetched, with a warning. The
  # reason is git's first fatal: line (its last line can be a hint), else its last.
  if reason=$(git -C "$LIB" fetch -q --depth 1 origin "+refs/heads/$rev:refs/remotes/origin/$rev" 2>&1); then
    new=$(git -C "$LIB" rev-parse "refs/remotes/origin/$rev^{commit}")
  elif reason=$({ grep -m1 '^fatal:' <<<"$reason" || tail -n1 <<<"$reason"; }) &&
    new=$(git -C "$LIB" rev-parse -q --verify "refs/remotes/origin/$rev^{commit}" 2>/dev/null); then
    echo "warning: couldn't reach the library: $reason; using $rev as last fetched, ${new:0:12}" >&2
  else
    echo "error: couldn't fetch branch $rev from $url: $reason" >&2; return 1
  fi
  [ "$(git -C "$LIB" rev-parse HEAD 2>/dev/null)" = "$new" ] && return 0
  git -C "$LIB" checkout -q --detach "$new" || { echo "error: couldn't check out $new in $LIB" >&2; return 1; }
  echo "The library's $rev is at $new: checked out into .library/" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  library_dir "${1:-$(cd "$(dirname "$0")/.." && pwd)}"
  echo "$LIB"
fi
