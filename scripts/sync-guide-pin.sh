#!/usr/bin/env bash
# Point the install guide's links into the library at the library commit this
# repository pins, so the component reference a page links to matches the pin.
#
#   scripts/sync-guide-pin.sh           rewrite README.md and docs/install/**/*.md
#   scripts/sync-guide-pin.sh --check   change nothing; exit 1 if a link differs
#
# The pin is libraryRevision in root/applicationset.yaml, and the library is
# libraryRepoURL there (a github.com URL). A link is any
# https://github.com/OWNER/ai-grid-cluster-gitops/blob/SHA/PATH with a full SHA,
# except a PATH under docs/install/: the library's main branch has no install
# reference, so those links stay at the commit that has it (README.md).
set -euo pipefail

cd "$(dirname "$0")/.."
check=false
case "${1:-}" in
  --check) check=true ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

root=root/applicationset.yaml
. scripts/library.sh
rev=$(library_pin . libraryRevision)
url=$(library_pin . libraryRepoURL)
if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
  echo "libraryRevision in $root isn't a full 40-character SHA: '$rev'" >&2; exit 1
fi
web=${url%.git}
if ! [[ "$web" =~ ^https://github\.com/[^/]+/[^/]+$ ]]; then
  echo "libraryRepoURL in $root isn't a github.com repository URL: '$url'" >&2; exit 1
fi
want="$web/blob/$rev/"
out=$(python3 - "$want" "$check" README.md $(find docs/install -name '*.md') <<'PY2'
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
  echo "$stale link(s) differ from the pin; run $0" >&2; exit 1
fi
echo "guide links at $want"
