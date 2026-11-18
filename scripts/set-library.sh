#!/usr/bin/env bash
# Set the library revision the hub reads: check REVISION (a branch, a tag or a
# full commit SHA) against libraryRepoURL in root/applicationset.yaml, and write
# it into libraryRevision there, the root's one place for it (the generators'
# revisions are YAML aliases of it).
#
# - A branch, such as main, is written as its name: Argo CD follows the branch,
#   so the hub updates when the branch moves. It prints "following URL branch
#   BRANCH (now at SHA)", or "already following".
# - A tag or a full SHA is written as the commit's SHA: the hub stays at that
#   commit until you set another. It prints "pinned URL at SHA (REVISION)", or
#   "already pinned".
#
# Only that value changes; every comment and line around it stays, and so does
# its YAML anchor (libraryRevision: &libraryRevision VALUE). It doesn't commit:
# commit root/applicationset.yaml yourself, or with scripts/git-push.sh.
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
# A tag's commit (peeled) first, then the tag, then a branch, then a full ref
# name; each as "SHA KIND", KIND branch for a branch (refs/heads/NAME or NAME).
read -r sha kind < <(awk -v r="$rev" '
  $2 == "refs/tags/" r "^{}" { p[1] = $1 } $2 == "refs/tags/" r { p[2] = $1 }
  $2 == "refs/heads/" r { p[3] = $1 }      $2 == r { p[4] = $1 }
  END { for (i = 1; i <= 4; i++) if (p[i] != "") {
          print p[i], (i == 3 || (i == 4 && r ~ /^refs\/heads\//)) ? "branch" : "commit"; exit } }' <<<"$refs") || true
sha=${sha:-} kind=${kind:-}
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

# A branch is written as its name. The root holds the value unquoted, and the
# ApplicationSet refuses an input with " ' \ or @, so a branch name with
# anything but letters, digits, . _ / and -, or one YAML reads as a number or
# a boolean (1.0, 0x1f, 1e5, .inf, true, no), can only be pinned.
value=$sha
if [ "$kind" = branch ]; then
  value=${rev#refs/heads/}
  shopt -s nocasematch
  if ! [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$value" =~ ^[-+0-9._]+$ ]] ||
    [[ "$value" =~ ^[-+]?0[xo] ]] || [[ "$value" =~ ^[-+]?\.(inf|nan)$ ]] ||
    [[ "$value" =~ ^[-+]?[0-9_]*\.?[0-9_]*e[-+]?[0-9]+$ ]] ||
    [[ "$value" =~ ^(y|n|yes|no|true|false|on|off|null)$ ]]; then
    echo "error: the root can't follow branch $value (only letters, digits, . _ / and -, and not a number or a boolean): pin a commit instead: set-library.sh $sha" >&2; exit 1
  fi
  shopt -u nocasematch
fi

python3 - "$k" "$value" "$url" "$rev" "$sha" "$kind" <<'PY'
import os, re, sys
path, value, url, rev, sha, kind = sys.argv[1:]
before = text = open(path).read()
places = [
    # The value is anything but a YAML anchor (&name) or alias (*name).
    ("libraryRevision", r"(^\s*libraryRevision:[ \t]*(?:&[\w-]+[ \t]+)?)([^\s#&*][^\s#]*)"),
]
for name, pattern in places:
    found = re.findall(pattern, text, flags=re.M)
    if len(found) != 1:
        sys.exit(f"error: {path} has {len(found)} places for {name}, not 1; set it by hand")
    text = re.sub(pattern, lambda m: m.group(1) + value, text, flags=re.M)
if kind == "branch":
    done = f"following {url} branch {value} (now at {sha})"
else:
    done = f"pinned {url} at {sha} ({rev})"
if text == before:
    print("already " + done)
    sys.exit(0)
tmp = path + ".tmp"
open(tmp, "w").write(text)
os.replace(tmp, path)
print(done)
PY
