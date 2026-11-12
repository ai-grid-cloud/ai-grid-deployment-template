#!/usr/bin/env bash
# Empty your catalog repository before an uninstall (install guide, page 8;
# make empty-catalog). Clones catalogRepoURL at catalogRevision, both from
# root/inputs.env, into a temporary directory and lists every file but
# README.md. A preview by default; --confirm removes them, commits
# "catalog: empty for uninstall" and pushes with your git credentials.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)"
confirm=""; [ "${1:-}" = --confirm ] && confirm=1
inputs="$dir/root/inputs.env"
value() { [ -f "$inputs" ] && sed -n "s/^$1=//p" "$inputs" | tail -n1; }
url=$(value catalogRepoURL || true) rev=$(value catalogRevision || true); rev=${rev:-main}
case "$url" in ""|REQUIRED-*)
  echo "error: root/inputs.env has no catalogRepoURL: run scripts/set-inputs.sh CATALOG_REPO_URL (page 2)" >&2; exit 1 ;;
esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone -q --branch "$rev" -- "$url" "$tmp/catalog"
cd "$tmp/catalog"
files=$(git ls-files | grep -vx README.md || true)
[ -n "$files" ] || { echo "The catalog $url ($rev) is already empty."; exit 0; }
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
