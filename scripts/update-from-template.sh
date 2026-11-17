#!/usr/bin/env bash
# Merge the template's latest main into this repository (make update).
#
# A repository created with "Use this template" starts as a copy of one
# template commit, with no shared history. The first update finds that commit
# (the template commit whose files equal your first commit's) and records it as
# merged, so the merge sees only the template's changes since then and yours.
# When the template's copy of this script differs from yours, it runs the
# template's instead, so a fix to the updater applies on the update that
# brings it. It changes nothing until your working tree is clean, and never
# pushes. After the merge it runs check-deployment.sh, and if the check fails,
# it says not to push. A repository that isn't installed yet (no
# root/inputs.env, which make install or make inputs writes) skips the check.
set -euo pipefail
url=${TEMPLATE_URL:-https://github.com/ai-grid-cloud/ai-grid-deployment-template.git}
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ -n "${UPDATE_FROM_TEMPLATE_LATEST:-}" ]; then rm -f "$0"; cd "$UPDATE_FROM_TEMPLATE_LATEST"; else cd "$(dirname "$0")/.."; fi
[ -z "$(git status --porcelain)" ] || { echo "error: commit or stash your changes first" >&2; exit 1; }
if git remote get-url template >/dev/null 2>&1; then git remote set-url template "$url"; else git remote add template "$url"; fi
git fetch -q template main
if [ -z "${UPDATE_FROM_TEMPLATE_LATEST:-}" ]; then
  latest=$(mktemp)
  if git show template/main:scripts/update-from-template.sh > "$latest" 2>/dev/null && ! cmp -s "$latest" "$self"; then
    echo "Running the template's latest update script."
    UPDATE_FROM_TEMPLATE_LATEST=$(pwd) exec bash "$latest" "$@"
  fi
  rm -f "$latest"
fi
if ! git merge-base HEAD template/main >/dev/null; then
  root=$(git rev-list --max-parents=0 HEAD | tail -n1)
  tree=$(git rev-parse "$root^{tree}")
  start=$(git log --format='%H %T' template/main | awk -v t="$tree" '!f && $2 == t {print $1; f = 1}')
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
  conflicts=$(git diff --name-only --diff-filter=U)
  echo "error: conflict in $(tr '\n' ' ' <<<"$conflicts")" >&2
  if grep -qx root/inputs.yaml <<<"$conflicts"; then
    # Before 320f038 your inputs were in root/inputs.yaml; now set-inputs.sh writes root/inputs.env.
    catalog=$(sed -nE 's/.*&catalogRepoURL[[:space:]]+([^[:space:]]+).*/\1/p' root/inputs.yaml | head -n1)
    case "$catalog" in ""|REQUIRED-*) catalog=CATALOG_REPO_URL ;; esac
    echo "The template replaced root/inputs.yaml with root/inputs.env. Write root/inputs.env from your values:" >&2
    echo "  make inputs CATALOG=$catalog" >&2
    echo "It sets both revisions to main; if root/inputs.yaml has another deploymentRevision or catalogRevision," >&2
    echo "copy it into root/inputs.env. Then remove the old file and finish the merge:" >&2
    echo "  git rm root/inputs.yaml" >&2
    echo "  git add root/inputs.env && git commit" >&2
  fi
  if grep -q '^tenant-idp/' <<<"$conflicts"; then
    # The template's own tenant Keycloak (tenant-idp/) gave way to the library's (apps/keycloak).
    echo "The template removed its own tenant Keycloak (tenant-idp/): the hub now runs the library's Keycloak in" >&2
    echo "maas-db. Remove the old files, finish the merge, then drop the old tenant IdP inputs:" >&2
    echo "  git rm -rq tenant-idp && git commit --no-edit" >&2
    echo "  make inputs" >&2
  fi
  if grep -qvx -e root/inputs.yaml -e 'tenant-idp/.*' <<<"$conflicts"; then
    echo "Edit each file to keep your values and the template's other changes, then: git add FILE ... && git commit" >&2
  fi
  echo "Or undo the merge: git merge --abort" >&2
  exit 1
fi
echo "Merged the template's main ($(git rev-parse --short template/main))."

if [ -d root ] && [ ! -f root/inputs.env ] && grep -q 'inputs.env' root/kustomization.yaml 2>/dev/null \
  && [ -z "$(git log -1 --format=%h -- root/inputs.env)" ]; then
  # Not installed yet: make install (page 9) or make inputs (page 2) writes it,
  # and check-deployment.sh can't render the root without it. A file that was
  # committed and then removed is still checked.
  echo "Not checked: root/inputs.env isn't written yet. make install, or make inputs CATALOG=CATALOG_REPO_URL (install guide, page 2), writes it and runs the check."
elif [ -d root ]; then
  if ! scripts/check-deployment.sh; then
    echo >&2
    echo "!! The merged repository doesn't pass scripts/check-deployment.sh. DON'T PUSH: fix what it names first." >&2
    exit 1
  fi
fi
echo "Review it with git diff ORIG_HEAD, then git push."
