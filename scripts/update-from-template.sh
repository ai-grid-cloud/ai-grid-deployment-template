#!/usr/bin/env bash
# Merge the template's latest main into this repository (make update).
#
# A repository created with "Use this template" starts as a copy of one
# template commit, with no shared history. The first update finds that commit
# (the template commit whose files equal your first commit's) and records it as
# merged, so the merge sees only the template's changes since then and yours.
# It changes nothing until your working tree is clean, and never pushes.
set -euo pipefail
url=${TEMPLATE_URL:-https://github.com/ai-grid-cloud/ai-grid-deployment-template.git}
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "error: commit or stash your changes first" >&2; exit 1; }
if git remote get-url template >/dev/null 2>&1; then git remote set-url template "$url"; else git remote add template "$url"; fi
git fetch -q template main
if ! git merge-base HEAD template/main >/dev/null; then
  root=$(git rev-list --max-parents=0 HEAD | tail -n1)
  tree=$(git rev-parse "$root^{tree}")
  start=$(git log --format='%H %T' template/main | awk -v t="$tree" '$2 == t {print $1; exit}')
  if [ -n "$start" ]; then
    echo "Your repository started from the template at ${start:0:7}."
    git merge -q --allow-unrelated-histories -s ours -m "Record the template commit this repository started from" "$start"
  else
    echo "error: no template commit matches your first commit, so git can't tell your changes from the template's." >&2
    echo "Merge by hand: git merge --allow-unrelated-histories template/main, keeping your values in each conflict." >&2
    exit 1
  fi
fi
if git merge-base --is-ancestor template/main HEAD; then echo "Already up to date with the template."; exit 0; fi
if ! git merge -q --no-edit -m "Merge the template's main" template/main; then
  echo "error: conflict in $(git diff --name-only --diff-filter=U | tr '\n' ' ')" >&2
  echo "Edit each file to keep your values and the template's other changes, then: git add FILE ... && git commit" >&2
  echo "Or undo the merge: git merge --abort" >&2
  exit 1
fi
echo "Merged the template's main ($(git rev-parse --short template/main)). Review it with git diff ORIG_HEAD, run scripts/check-deployment.sh, then git push."
