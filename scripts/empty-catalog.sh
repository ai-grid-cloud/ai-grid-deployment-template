#!/usr/bin/env bash
# Empty your catalog repository before an uninstall (install guide, page 8;
# make empty-catalog). Clones catalogRepoURL at catalogRevision, both from
# root/inputs.env, into a temporary directory and lists every file but
# README.md. A preview by default; --confirm removes them, commits
# "catalog: empty for uninstall" and pushes.
#
# --check is read-only (make install uses it): it exits 0 when the catalog
# holds nothing but README.md, and 1, listing the files, when it holds more
# or can't be read.
#
# The catalog token comes from scripts/clusters.sh's deployment_load
# (github.catalogToken, the environment winning, else CATALOG_TOKEN_FILE).
# With one, git reads it through a temporary GIT_ASKPASS helper and never
# prompts, so the token is never on a command line or in the output; without
# one, --confirm uses your own git credentials.
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
  echo "error: root/inputs.env has no catalogRepoURL: run make inputs CATALOG=CATALOG_REPO_URL (page 2)" >&2; exit 1 ;;
esac
if [ -f "$dir/.config/clusters.yaml" ] || [ -f "$dir/clusters.yaml" ]; then
  . "$dir/scripts/clusters.sh"; deployment_load "$dir" || exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
token_file=${CATALOG_TOKEN_FILE:-} gitc=(git)
if [ -n "$token_file" ] && [ -r "$token_file" ]; then
  # The helper holds the file's path, never its contents.
  printf '#!/bin/bash\ncase "$1" in Username*) echo x-access-token ;; *) head -n1 %q ;; esac\n' "$token_file" > "$tmp/askpass"
  chmod 700 "$tmp/askpass"; export GIT_ASKPASS="$tmp/askpass" GIT_TERMINAL_PROMPT=0
  gitc=(git -c credential.helper=)
fi
if [ -n "$check" ]; then
  export GIT_TERMINAL_PROMPT=0
  err=$("${gitc[@]}" clone -q --depth 1 --branch "$rev" -- "$url" "$tmp/catalog" 2>&1) ||
    { echo "error: can't read the catalog $url ($rev): $(grep . <<<"$err" | tail -n1)" >&2; exit 1; }
else
  "${gitc[@]}" clone -q --branch "$rev" -- "$url" "$tmp/catalog"
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
"${gitc[@]}" push -q origin "HEAD:$rev"
echo "Pushed: the catalog $url ($rev) now holds only README.md."
