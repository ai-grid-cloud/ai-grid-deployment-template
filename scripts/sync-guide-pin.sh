#!/usr/bin/env bash
# Point the install guide's links into the library at the library commit this
# repository pins, so the component reference a page links to matches the pin.
#
#   scripts/sync-guide-pin.sh           rewrite README.md and docs/install/**/*.md
#   scripts/sync-guide-pin.sh --check   change nothing; exit 1 if a link differs
#
# The pin is values.libraryRevision in root/kustomization.yaml, and the library
# is values.libraryRepoURL there (a github.com URL). A link is any
# https://github.com/OWNER/ai-grid-cluster-gitops/blob/SHA/ with a full SHA.
set -euo pipefail

cd "$(dirname "$0")/.."
check=false
case "${1:-}" in
  --check) check=true ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

root=root/kustomization.yaml
rev=$(sed -n -E 's/^[[:space:]]*libraryRevision:[[:space:]]*([^[:space:]#]+).*/\1/p' "$root" | head -n1)
url=$(sed -n -E 's/^[[:space:]]*libraryRepoURL:[[:space:]]*([^[:space:]#]+).*/\1/p' "$root" | head -n1)
if ! [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
  echo "libraryRevision in $root isn't a full 40-character SHA: '$rev'" >&2; exit 1
fi
web=${url%.git}
if ! [[ "$web" =~ ^https://github\.com/[^/]+/[^/]+$ ]]; then
  echo "libraryRepoURL in $root isn't a github.com repository URL: '$url'" >&2; exit 1
fi
want="$web/blob/$rev/"
link='https://github\.com/[^/)]+/ai-grid-cluster-gitops/blob/[0-9a-f]{40}/'

stale=0
while IFS= read -r -d '' f; do
  others=$(grep -oE "$link" "$f" | grep -vxF "$want" || true)
  [ -z "$others" ] && continue
  n=$(printf '%s\n' "$others" | wc -l | tr -d ' ')
  stale=$((stale + n))
  if $check; then
    echo "$f: $n link(s) not at $want"
  else
    sed -E -i.bak "s#$link#$want#g" "$f" && rm -f "$f.bak"
    echo "$f: $n link(s) moved to $want"
  fi
done < <(find README.md docs/install -name '*.md' -print0)

if $check && [ "$stale" -gt 0 ]; then
  echo "$stale link(s) differ from the pin; run $0" >&2; exit 1
fi
echo "guide links at $want"
