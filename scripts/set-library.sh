#!/usr/bin/env bash
# Pin the library at a revision: resolve REVISION (a branch, a tag or a full
# commit SHA) against libraryRepoURL in root/applicationset.yaml, and write the
# SHA into libraryRevision there, the root's one pin place (the generators'
# revisions are YAML aliases of it).
#
# Only that value changes; every comment and line around it stays, and so does
# its YAML anchor (libraryRevision: &libraryRevision SHA). It prints "pinned URL
# at SHA (REVISION)", or "already pinned" when the root already pins that SHA.
# It doesn't commit: commit root/applicationset.yaml yourself, or with
# scripts/git-push.sh.
#
# Usage: scripts/set-library.sh REVISION
# Exit 1 when REVISION isn't in the library, 2 on a usage error.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: set-library.sh REVISION" >&2; exit 2; }
rev=$1
k="$dir/root/applicationset.yaml"
. "$here/library.sh"
url=$(library_pin "$dir" libraryRepoURL)
[ -n "$url" ] || { echo "error: no libraryRepoURL in $k" >&2; exit 1; }
export GIT_TERMINAL_PROMPT=0

refs=$(git ls-remote "$url" 2>&1) || { echo "error: can't read the library at $url: $(tail -n1 <<<"$refs")" >&2; exit 1; }
# A tag's commit (peeled) first, then the tag, then a branch, then a full ref name.
sha=$(awk -v r="$rev" '
  $2 == "refs/tags/" r "^{}" { p[1] = $1 } $2 == "refs/tags/" r { p[2] = $1 }
  $2 == "refs/heads/" r { p[3] = $1 }      $2 == r { p[4] = $1 }
  END { for (i = 1; i <= 4; i++) if (p[i] != "") { print p[i]; exit } }' <<<"$refs")
if [ -z "$sha" ] && [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
  if grep -q "^$rev[[:space:]]" <<<"$refs"; then
    sha=$rev
  else # not a ref tip: prove the commit exists by fetching it
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    git init -q "$tmp" && reason=$(git -C "$tmp" fetch -q --depth 1 "$url" "$rev" 2>&1) &&
      git -C "$tmp" cat-file -e "$rev^{commit}" 2>/dev/null && sha=$rev
  fi
fi
if [ -z "$sha" ]; then
  why=""
  [ -n "${reason:-}" ] && why=": $(tail -n1 <<<"$reason")"
  [[ "$rev" =~ ^[0-9a-f]{4,39}$ ]] && why="$why; if it's a commit, use a full 40-character SHA"
  echo "error: $rev isn't a branch, tag or commit in the library at $url$why" >&2; exit 1
fi

python3 - "$k" "$sha" "$url" "$rev" <<'PY'
import os, re, sys
path, sha, url, rev = sys.argv[1:]
before = text = open(path).read()
places = [
    ("libraryRevision", r"(^\s*libraryRevision:[ \t]*(?:&[\w-]+[ \t]+)?)([0-9a-f]{40})\b"),
]
for name, pattern in places:
    found = re.findall(pattern, text, flags=re.M)
    if len(found) != 1:
        sys.exit(f"error: {path} has {len(found)} places for {name}, not 1; pin it by hand")
    text = re.sub(pattern, lambda m: m.group(1) + sha, text, flags=re.M)
if text == before:
    print(f"already pinned {url} at {sha} ({rev})")
    sys.exit(0)
tmp = path + ".tmp"
open(tmp, "w").write(text)
os.replace(tmp, path)
print(f"pinned {url} at {sha} ({rev})")
PY
