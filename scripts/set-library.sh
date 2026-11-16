#!/usr/bin/env bash
# Pin the library at a revision: resolve REVISION (a branch, a tag or a full
# commit SHA) against libraryRepoURL in root/kustomization.yaml, and write the
# SHA into the root's three pin places in one go:
#
#   the remote base            ...//bootstrap/hub?ref=SHA
#   the generator revision     /spec/generators/0/git/revision's replace value
#   values.libraryRevision     libraryRevision: SHA
#
# Only those three values change; every comment and line around them stays,
# and so does a YAML anchor on the value (value: &libraryRevision SHA).
# It prints "pinned URL at SHA (REVISION)", or "already pinned" when the root
# already pins that SHA. It doesn't commit: commit root/kustomization.yaml
# yourself, or with scripts/git-push.sh.
#
# Usage: scripts/set-library.sh REVISION
# Exit 1 when REVISION isn't in the library or the remote base names another
# repository than libraryRepoURL, 2 on a usage error.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: set-library.sh REVISION" >&2; exit 2; }
rev=$1
k="$dir/root/kustomization.yaml"
url=$(sed -n -E 's/^[[:space:]]*libraryRepoURL:[[:space:]]*([^[:space:]#]+).*/\1/p' "$k" | head -n1)
[ -n "$url" ] || { echo "error: no libraryRepoURL in $k" >&2; exit 1; }
base=$(sed -n -E 's#^[[:space:]]*-[[:space:]]+([^[:space:]]+)//bootstrap/hub\?ref=.*#\1#p' "$k" | head -n1)
if [ -n "$base" ] && [ "${base%.git}" != "${url%.git}" ]; then
  echo "error: the remote base in $k names $base, but libraryRepoURL is $url; make them the same repository" >&2; exit 1
fi
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
    ("the remote base", r"(^\s*-\s+\S+//bootstrap/hub\?ref=)([^\s#]+)"),
    ("the generator revision", r"(\{\s*op:\s*replace,\s*path:\s*/spec/generators/0/git/revision,\s*value:\s*(?:&[\w-]+\s+)?)([^\s,}#]+)"),
    ("values.libraryRevision", r"(^\s*libraryRevision:\s*)([^\s#]+)"),
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
