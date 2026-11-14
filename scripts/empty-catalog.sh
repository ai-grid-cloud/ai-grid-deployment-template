#!/usr/bin/env bash
# Empty your catalog repository before an uninstall (install guide, page 8;
# make empty-catalog). Clones catalogRepoURL at catalogRevision, both from
# root/inputs.env, into a temporary directory and lists every file but
# README.md. A preview by default; --confirm removes them, commits
# "catalog: empty for uninstall" and pushes with your git credentials.
#
# --check is read-only (make install uses it): it exits 0 when the catalog
# holds nothing but README.md, and 1, listing the files, when it holds more
# or can't be read. It never asks for a password: when CATALOG_TOKEN_FILE
# names a readable file, git reads the token from it through a temporary
# GIT_ASKPASS helper, so the token is never on a command line or in the output.
#
# Usage: scripts/empty-catalog.sh [--confirm | --check]
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)"
confirm="" check=""
case "${1:-}" in --confirm) confirm=1 ;; --check) check=1 ;; esac
inputs="$dir/root/inputs.env"
value() { [ -f "$inputs" ] && sed -n "s/^$1=//p" "$inputs" | tail -n1; }
url=$(value catalogRepoURL || true) rev=$(value catalogRevision || true); rev=${rev:-main}
case "$url" in ""|REQUIRED-*)
  echo "error: root/inputs.env has no catalogRepoURL: run scripts/set-inputs.sh CATALOG_REPO_URL (page 2)" >&2; exit 1 ;;
esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$check" ]; then
  export GIT_TERMINAL_PROMPT=0
  token_file=${CATALOG_TOKEN_FILE:-}
  if [ -n "$token_file" ] && [ -r "$token_file" ]; then
    # The helper holds the file's path, never its contents.
    printf '#!/bin/bash\ncase "$1" in Username*) echo x-access-token ;; *) head -n1 %q ;; esac\n' "$token_file" > "$tmp/askpass"
    chmod 700 "$tmp/askpass"; export GIT_ASKPASS="$tmp/askpass"
  fi
  err=$(git -c credential.helper= clone -q --depth 1 --branch "$rev" -- "$url" "$tmp/catalog" 2>&1) ||
    { echo "error: can't read the catalog $url ($rev): $(grep . <<<"$err" | tail -n1)" >&2; exit 1; }
else
  git clone -q --branch "$rev" -- "$url" "$tmp/catalog"
fi
cd "$tmp/catalog"
files=$(git ls-files | grep -vx README.md || true)
[ -n "$files" ] || { echo "The catalog $url ($rev) is already empty."; exit 0; }
if [ -n "$check" ]; then
  echo "error: the catalog $url ($rev) isn't empty; the install never empties it. It holds:" >&2
  sed 's/^/  /' <<<"$files" >&2
  echo "Use an empty catalog repository (only README.md), or empty this one with make empty-catalog." >&2
  exit 1
fi
echo "Removes from the catalog $url ($rev):"
sed 's/^/  /' <<<"$files"
if [ -z "$confirm" ]; then
  echo "Preview only: nothing changed. Run make empty-catalog CONFIRM=1 to commit and push."
  exit 0
fi
git ls-files -z | grep -zvx README.md | xargs -0 git rm -q --
git commit -q -m "catalog: empty for uninstall"
git push -q origin "HEAD:$rev"
echo "Pushed: the catalog $url ($rev) now holds only README.md."
