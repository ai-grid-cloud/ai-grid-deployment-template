#!/usr/bin/env bash
# Merge the template's latest main into this repository (make update).
#
# A repository created with "Use this template" starts as a copy of one
# template commit, with no shared history. The first update finds that commit
# (the template commit whose files equal your first commit's) and records it as
# merged, so the merge sees only the template's changes since then and yours.
# It changes nothing until your working tree is clean, and never pushes.
#
# After the merge it moves your inputs if the template moved them: when the
# merge brings root/inputs.yaml with REQUIRED- values that your root before the
# merge set in root/kustomization.yaml, it writes those values into
# root/inputs.yaml, resets those lines in root/kustomization.yaml to the
# template's, and commits that on its own. Then it runs check-deployment.sh,
# and if the check fails it says not to push.
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
echo "Merged the template's main ($(git rev-parse --short template/main))."

# Your inputs moved from root/kustomization.yaml to root/inputs.yaml (and may
# again): carry the values your root had before the merge.
if [ -f root/inputs.yaml ] && ! git cat-file -e ORIG_HEAD:root/inputs.yaml 2>/dev/null &&
   git cat-file -e ORIG_HEAD:root/kustomization.yaml 2>/dev/null; then
  moved=$(python3 - "$(git show ORIG_HEAD:root/kustomization.yaml)" "$(git show template/main:root/kustomization.yaml)" <<'PY'
import re, sys
old, tpl = sys.argv[1], sys.argv[2]
names = ["deploymentRepoURL", "deploymentRevision", "catalogRepoURL", "catalogRevision", "idpIssuerURL"]
def value(text, n):  # the first "n: [&n ]VALUE" line's value
    m = re.search(r"^\s*%s:\s*(?:&%s\s+)?(\S+)\s*$" % (n, n), text, re.M)
    return m.group(1) if m else None
inputs = open("root/inputs.yaml").read()
kust = open("root/kustomization.yaml").read()
for n in names:
    v = value(old, n)
    if not v or v.startswith("REQUIRED-"):
        continue
    new, k = re.subn(r"(value: &%s )\S+" % n, lambda m: m.group(1) + v, inputs, count=1)
    if k and new != inputs:
        inputs = new
        print(f"  {n}: {v}")
    # Your old line in kustomization.yaml goes back to the template's.
    t = re.search(r"^\s*%s:.*$" % n, tpl, re.M)
    if t:
        kust = re.sub(r"^\s*%s:.*$" % n, lambda m: t.group(0), kust, count=1, flags=re.M)
open("root/inputs.yaml", "w").write(inputs)
open("root/kustomization.yaml", "w").write(kust)
PY
)
  if [ -n "$(git status --porcelain root)" ]; then
    git add root/inputs.yaml root/kustomization.yaml
    git commit -q -m "root: move your inputs to inputs.yaml"
    echo "Moved your inputs to root/inputs.yaml (its own commit):"
    [ -z "$moved" ] || echo "$moved"
  fi
fi

if [ -d root ]; then
  if ! scripts/check-deployment.sh; then
    echo >&2
    echo "!! The merged repository doesn't pass scripts/check-deployment.sh. DON'T PUSH: fix what it names first." >&2
    exit 1
  fi
fi
echo "Review it with git diff ORIG_HEAD, then git push."
