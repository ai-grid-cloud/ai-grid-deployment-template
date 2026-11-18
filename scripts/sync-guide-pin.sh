#!/usr/bin/env bash
# Point the install guide's links into the library at one library commit, so
# the component reference a page links to is stable and matches what you read.
#
#   scripts/sync-guide-pin.sh [REVISION]   rewrite README.md and docs/install/**/*.md
#   scripts/sync-guide-pin.sh --check      change nothing; exit 1 if a link differs
#
# A link always names a full commit SHA, never a branch, so it doesn't change
# under the reader. The commit is REVISION (a full SHA, or a branch or tag,
# resolved with git ls-remote); without it, libraryRevision in
# root/applicationset.yaml when that pins a commit, else the commit the branch
# libraryRevision follows (main by default) is at now. --check needs no
# network: with a pinned libraryRevision, every link must name that commit;
# with a branch, every link must name the same commit, whichever it is.
#
# The library is libraryRepoURL in root/applicationset.yaml (a github.com URL).
# A link is any https://github.com/OWNER/ai-grid-cluster-gitops/blob/SHA/PATH
# with a full SHA, except a PATH under docs/install/: the library's main branch
# has no install reference, so those links stay at the commit that has it
# (README.md).
set -euo pipefail

cd "$(dirname "$0")/.."
check=false target=""
case "${1:-}" in
  --check) check=true; [ $# -eq 1 ] || { echo "usage: $0 [--check | REVISION]" >&2; exit 2; } ;;
  -*) echo "usage: $0 [--check | REVISION]" >&2; exit 2 ;;
  *) target=${1:-}; [ $# -le 1 ] || { echo "usage: $0 [--check | REVISION]" >&2; exit 2; } ;;
esac

root=root/applicationset.yaml
. scripts/library.sh
rev=$(library_pin . libraryRevision)
url=$(library_pin . libraryRepoURL)
[ -n "$rev" ] || { echo "no libraryRevision in $root" >&2; exit 1; }
web=${url%.git}
if ! [[ "$web" =~ ^https://github\.com/[^/]+/[^/]+$ ]]; then
  echo "libraryRepoURL in $root isn't a github.com repository URL: '$url'" >&2; exit 1
fi
files=(README.md $(find docs/install -name '*.md'))
link_re='https://github\.com/[^/)]+/ai-grid-cluster-gitops/blob/[0-9a-f]{40}/'

if $check; then
  if library_is_sha "$rev"; then
    sha=$rev
  else # following a branch: the one commit the links name, whichever it is
    shas=$(grep -hoE "${link_re}[^)[:space:]]*" "${files[@]}" | grep -vE '/blob/[0-9a-f]{40}/docs/install/' |
      sed -E 's#.*/blob/([0-9a-f]{40})/.*#\1#' | sort -u || true)
    if [ "$(grep -c . <<<"$shas")" -gt 1 ]; then
      echo "the guide's links name two or more commits of the library:" >&2; sed 's/^/  /' <<<"$shas" >&2
      echo "run $0 to move them to one" >&2; exit 1
    fi
    [ -n "$shas" ] || { echo "no guide links into the library"; exit 0; }
    sha=$shas
  fi
else
  target=${target:-$rev}
  if library_is_sha "$target"; then
    sha=$target
  else # a branch or tag: the commit it is at now
    sha=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$url" "refs/tags/$target^{}" "refs/tags/$target" "refs/heads/$target" 2>/dev/null |
      awk -v r="$target" '$2 == "refs/tags/" r "^{}" {p[1] = $1} $2 == "refs/tags/" r {p[2] = $1} $2 == "refs/heads/" r {p[3] = $1}
        END {for (i = 1; i <= 3; i++) if (p[i] != "") {print p[i]; exit}}')
    [ -n "$sha" ] || { echo "error: $target isn't a branch or tag in the library at $url; for a commit, use its full 40-character SHA" >&2; exit 1; }
  fi
fi
want="$web/blob/$sha/"
out=$(python3 - "$want" "$check" "${files[@]}" <<'PY2'
import re, sys
want, check, files = sys.argv[1], sys.argv[2] == "true", sys.argv[3:]
link = re.compile(r"https://github\.com/[^/)]+/ai-grid-cluster-gitops/blob/[0-9a-f]{40}/(?!docs/install/)")
stale = 0
for f in files:
    text = open(f).read()
    others = [m.group(0) for m in link.finditer(text) if m.group(0) != want]
    if not others:
        continue
    stale += len(others)
    if check:
        print(f"{f}: {len(others)} link(s) not at {want}")
    else:
        open(f, "w").write(link.sub(want, text))
        print(f"{f}: {len(others)} link(s) moved to {want}")
print(f"stale={stale}")
PY2
)
stale=$(sed -n 's/^stale=//p' <<<"$out")
grep -v '^stale=' <<<"$out" || true
if $check && [ "$stale" -gt 0 ]; then
  echo "$stale link(s) differ from $sha; run $0" >&2; exit 1
fi
echo "guide links at $want"
