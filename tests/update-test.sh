#!/usr/bin/env bash
# Tests for scripts/update-from-template.sh against local repositories.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?; printf '%s\n' "$out" > "$T/last"
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The template: its scripts and a guide file.
tpl="$T/template"; mkdir -p "$tpl"; cp -R "$SRC/scripts" "$tpl/"; echo v1 > "$tpl/guide.md"; echo "hub hub - x" > "$tpl/clusters"
g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm v1
# A repository created from it ("Use this template"): the same files in a new
# first commit with no shared history; then your clusters.
mine="$T/mine"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/guide.md" "$tpl/clusters" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
echo "hub hub - mine" > "$mine/clusters"; g -C "$mine" commit -qam "my clusters"
echo v2 > "$tpl/guide.md"; g -C "$tpl" commit -qam v2

run() { (cd "$mine" && TEMPLATE_URL="$tpl" bash scripts/update-from-template.sh); }
echo dirty >> "$mine/guide.md"
t "refuses uncommitted changes" 1 "commit or stash your changes first" run
g -C "$mine" checkout -q guide.md
t "first update finds the commit you started from" 0 "started from the template at [0-9a-f]{7}" run
t "takes the template's change" 0 "^v2$" cat "$mine/guide.md"
t "keeps your clusters" 0 "^hub hub - mine$" cat "$mine/clusters"
t "adds the template remote" 0 "^template$" g -C "$mine" remote
t "nothing new" 0 "Already up to date" run
echo v3 > "$tpl/guide.md"; g -C "$tpl" commit -qam v3
t "later update" 0 "Merged the template" run
t "later update takes the change" 0 "^v3$" cat "$mine/guide.md"
echo "mine too" > "$mine/guide.md"; g -C "$mine" commit -qam "my edit"; echo v4 > "$tpl/guide.md"; g -C "$tpl" commit -qam v4
t "a conflict stops with the fix" 1 "conflict.*guide.md" run
(cd "$mine" && git merge --abort)

# A fix to the updater reaches you on this update: make update runs the
# template's latest scripts/update-from-template.sh, not your older copy.
sed -i.bak 's#^set -euo pipefail$#&\necho "template updater marker"#' "$tpl/scripts/update-from-template.sh"
rm "$tpl/scripts/update-from-template.sh.bak"; echo v5 > "$tpl/guide.md"; g -C "$tpl" commit -qam "a newer updater"
g -C "$mine" checkout -q -- . ; echo "mine" > "$mine/guide.md"; g -C "$mine" commit -qam "mine"
t "runs the template's latest updater" 1 "Running the template's latest update script" run
t "  ... which is the template's" 0 "^template updater marker$" cat "$T/last"
t "  ... once" 0 "^1$" grep -c "Running the template's latest" "$T/last"
(cd "$mine" && git merge --abort)

# With the real root/, pinned at a local copy of the library's commits (lib2):
# check-deployment.sh runs offline (it reads no library).
# lib2 is a repository of its own (never a copy of a library checkout, whose
# .git may be a worktree link back to a real library repository).
lib2="$T/lib2"; g init -q "$lib2"; g -C "$lib2" commit -q --allow-empty -m "a library commit"
pin() { git -C "$lib2" rev-parse HEAD; }
set_rev() { # root dir, revision: libraryRevision set to it
  sed -i.bak -E -e "s#^([[:space:]]*libraryRevision: &libraryRevision )[^[:space:]]+#\1$2#" "$1/applicationset.yaml"; rm "$1/applicationset.yaml.bak"
}
localize() { set_rev "$1" "$(pin)"; } # root dir: pinned at lib2's HEAD, as the template was before it followed main
fill_catalog() { # repo dir: hub/catalog names the catalog input, as set-inputs.sh writes it
  local f; for f in "$1"/hub/catalog/*.yaml; do
    sed -i.bak -e 's#REQUIRED-catalogRepoURL#https://github.com/acme/catalog.git#g' -e 's#REQUIRED-catalogRevision#main#g' "$f"; rm "$f.bak"
  done
}
runl() { (cd "$mine" && TEMPLATE_URL="$tpl" LIBRARY="$lib2" bash scripts/update-from-template.sh); }

# A repository from the template with its inputs set: root/inputs.env is its
# own file, which the template doesn't have.
tpl="$T/tpl-root"; mkdir -p "$tpl"; cp -R "$SRC/scripts" "$SRC/root" "$SRC/apps" "$SRC/hub" "$tpl/"; rm -f "$tpl/root/inputs.env"
localize "$tpl/root"; g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm "root"
mine="$T/mine-root"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$tpl/apps" "$tpl/hub" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
  catalogRepoURL=https://github.com/acme/catalog.git catalogRevision=main keycloakOverlay=core hubCertManager=library > "$mine/root/inputs.env"
fill_catalog "$mine"
g -C "$mine" add -A && g -C "$mine" commit -qm "set our names"

# A template commit that moves the library pin merges cleanly.
g -C "$lib2" commit -q --allow-empty -m "new pin"
localize "$tpl/root"; g -C "$tpl" commit -qam "move the pin"
t "a pin move merges with your inputs set, and checks" 0 "every repository is an input" runl
t "  ... takes the new pin" 0 "libraryRevision: &libraryRevision $(pin)" cat "$mine/root/applicationset.yaml"
t "  ... keeps your inputs" 0 "^catalogRepoURL=https://github.com/acme/catalog.git$" cat "$mine/root/inputs.env"
t "  ... in the merge commit only" 0 "^Merge the template's main$" g -C "$mine" log -1 --format=%s

# The template moves from its pinned commit to following the library's main:
# a deployment that kept the template's pin follows main after the update, as
# any template change it hasn't touched.
mk_pair() { # name: a template at lib2's pin and a deployment from it with its inputs set; sets tpl and mine
  tpl="$T/tpl-$1"; mkdir -p "$tpl"; cp -R "$SRC/scripts" "$SRC/root" "$SRC/apps" "$SRC/hub" "$tpl/"; rm -f "$tpl/root/inputs.env"
  localize "$tpl/root"; g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm "root"
  mine="$T/mine-$1"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$tpl/apps" "$tpl/hub" "$mine/"
  g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
  printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
    catalogRepoURL=https://github.com/acme/catalog.git catalogRevision=main keycloakOverlay=core hubCertManager=library > "$mine/root/inputs.env"
  fill_catalog "$mine"; g -C "$mine" add -A && g -C "$mine" commit -qm "set our names"
}
keep_tpl=$tpl keep_mine=$mine
mk_pair follow; was=$(pin)
set_rev "$tpl/root" main; g -C "$tpl" commit -qam "follow the library's main"
t "the template's pin was yours: the update follows main" 0 "every repository is an input" runl
cp "$T/last" "$T/out"
t "  ... libraryRevision is main" 0 "libraryRevision: &libraryRevision main$" cat "$mine/root/applicationset.yaml"
t "  ... says the hub follows main once you push" 0 "follows main once you push, instead of staying at $was" cat "$T/out"
t "  ... and how to stay at the old pin" 0 "run scripts/set-library.sh $was" cat "$T/out"
t "  ... no LIBRARY warning without options.LIBRARY" 1 "^0$" grep -c "next make install" "$T/out"
# options.LIBRARY in clusters.yaml wins at the next make install: the update says so
# when it differs from the merged revision, and only then.
clusters() { # repo, LIBRARY value: a committed clusters.yaml with that option
  printf "apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: 'https://api.hub.example.com:6443'}\noptions: {LIBRARY: %s}\n" "$2" > "$1/clusters.yaml"
  g -C "$1" add clusters.yaml && g -C "$1" commit -qm "our clusters"
}
mk_pair lib-option; clusters "$mine" v1.2
set_rev "$tpl/root" main; g -C "$tpl" commit -qam "follow the library's main"
t "options.LIBRARY differs from the merged revision: warns" 0 "options.LIBRARY is v1.2.*next make install" runl
mk_pair lib-main; clusters "$mine" main
set_rev "$tpl/root" main; g -C "$tpl" commit -qam "follow the library's main"
runl > "$T/last" 2>&1 || true
t "  ... options.LIBRARY main, the same: no warning" 1 "^0$" grep -c "next make install" "$T/last"
# A deployment that pinned its own commit (LIBRARY: SHA): the update never
# replaces it silently; the merge stops on that line and says what to choose.
mk_pair own-pin
g -C "$lib2" commit -q --allow-empty -m "the commit you pin"
set_rev "$mine/root" "$(pin)"; g -C "$mine" commit -qam "pin the library"
set_rev "$tpl/root" main; g -C "$tpl" commit -qam "follow the library's main"
t "your own pin: the update stops on it" 1 "conflict in root/applicationset.yaml" runl
cp "$T/last" "$T/out"
t "  ... says how to keep your pin or follow main" 0 "scripts/set-library.sh main" cat "$T/out"
t "  ... and that LIBRARY under options: wins at the next make install" 0 "LIBRARY under options: .*wins.*make install" cat "$T/out"
t "  ... your pin is still there" 0 "^ *libraryRevision: &libraryRevision $(pin)$" cat "$mine/root/applicationset.yaml"
(cd "$mine" && git merge --abort)
t "  ... and an abort keeps it" 0 "libraryRevision: &libraryRevision $(pin)$" cat "$mine/root/applicationset.yaml"
tpl=$keep_tpl mine=$keep_mine

# A merge that leaves an input unset says not to push.
sed -i.bak 's#^catalogRevision=.*#catalogRevision=#' "$mine/root/inputs.env"; rm "$mine/root/inputs.env.bak"
g -C "$mine" commit -qam "unset the catalog revision"; echo "# note" >> "$tpl/root/self.yaml"; g -C "$tpl" commit -qam "a template change"
t "a failing check says don't push" 1 "DON'T PUSH" runl

# Your tenant-idp settings, which the template deleted: the merge stops on them
# and prints how to finish.
mkdir -p "$tpl/tenant-idp/manifests"; echo "portalRedirectURI: REQUIRED-portalRedirectURI" > "$tpl/tenant-idp/manifests/settings.yaml"
g -C "$tpl" add -A && g -C "$tpl" commit -qm "tenant-idp"
g -C "$mine" checkout -q -- . 2>/dev/null || true
sed -i.bak 's#^catalogRevision=.*#catalogRevision=main#' "$mine/root/inputs.env"
rm "$mine/root/inputs.env.bak"; g -C "$mine" commit -qam "the catalog revision again"
runl >/dev/null 2>&1 || true
echo "portalRedirectURI: https://maas.apps.site.example.com/*" > "$mine/tenant-idp/manifests/settings.yaml"
g -C "$mine" commit -qam "my redirects"
g -C "$tpl" rm -rq tenant-idp && g -C "$tpl" commit -qm "the library's Keycloak"
t "a deleted tenant-idp/ you changed stops the merge" 1 "conflict in tenant-idp/manifests/settings.yaml" runl
cp "$T/last" "$T/out"
t "  ... says to remove it" 0 "^  git rm -rq tenant-idp && git commit --no-edit$" cat "$T/out"
t "  ... then make inputs" 0 "^  make inputs$" cat "$T/out"
t "  ... and not the generic edit-each-file line" 1 "^0$" grep -c "Edit each file" "$T/out"
finish() { (cd "$mine" && g rm -rq tenant-idp && g commit -q --no-edit && git status --porcelain); }
t "  ... and those steps finish the merge" 0 "^$" finish

# A repository from the template that was never installed: no root/inputs.env
# yet, which make install (or make inputs) writes. The update merges and says
# so, instead of failing the check.
mine="$T/mine-fresh"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$tpl/apps" "$tpl/hub" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
echo "# another note" >> "$tpl/root/self.yaml"; g -C "$tpl" commit -qam "another template change"
t "no inputs.env yet merges without don't push" 0 "root/inputs.env isn't written yet" runl
t "  ... names make install" 0 "make install" cat "$T/last"
t "  ... no DON'T PUSH" 1 "^0$" grep -c "DON'T PUSH" "$T/last"
# An installed repository whose root/inputs.env was committed, then removed: still checked.
echo "x=y" > "$mine/root/inputs.env"; g -C "$mine" add -A && g -C "$mine" commit -qm "inputs"
g -C "$mine" rm -q root/inputs.env && g -C "$mine" commit -qm "lose the inputs"
echo "# a third note" >> "$tpl/root/self.yaml"; g -C "$tpl" commit -qam "a third template change"
t "inputs.env committed, then removed: don't push" 1 "DON'T PUSH" runl

# A repository from the template before root/inputs.env (320f038), with its
# values in root/inputs.yaml, which the template has since deleted: the merge
# stops on that file and prints the commands that finish it.
# It reads that commit from this checkout's history, which a repository created
# with "Use this template" lacks until make update merges the template's main.
if ! git -C "$SRC" cat-file -e '320f03816f08f8a732af8188c5ed8c89628656e2^{commit}' 2>/dev/null; then
  echo "   skipped an old inputs.yaml: this checkout has no template commit 320f038"
else
  old=$(git -C "$SRC" rev-parse 320f03816f08f8a732af8188c5ed8c89628656e2^)
  tpl="$T/tpl-old"; mkdir -p "$tpl/root"; cp -R "$SRC/scripts" "$tpl/"
  for f in inputs.yaml kustomization.yaml self.yaml; do git -C "$SRC" show "$old:root/$f" > "$tpl/root/$f"; done
  g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm "old root"
  mine="$T/mine-old"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$mine/"
  g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
  sed -i.bak -e 's#REQUIRED-deploymentRepoURL#https://github.com/acme/deploy.git#' \
    -e 's#REQUIRED-catalogRepoURL#https://github.com/acme/catalog.git#' \
    -e 's#REQUIRED-idpIssuerURL#https://keycloak-maas-db.apps.hub.example.com/realms/saas#' \
    "$mine/root/inputs.yaml" "$mine/root/self.yaml"; rm "$mine/root/"*.bak
  g -C "$mine" commit -qam "set our names"
  rm -rf "$tpl/root"; cp -R "$SRC/root" "$tpl/"; rm -f "$tpl/root/inputs.env"; g -C "$tpl" add -A
  g -C "$tpl" commit -qm "inputs.env"
  t "an old inputs.yaml stops the merge" 1 "conflict in root/inputs.yaml" run
  cp "$T/last" "$T/out"
  t "  ... prints make inputs with your catalog URL" 0 "^  make inputs CATALOG=https://github.com/acme/catalog.git$" cat "$T/out"
  t "  ... then git rm root/inputs.yaml" 0 "^  git rm root/inputs.yaml$" cat "$T/out"
  t "  ... then add inputs.env and commit" 0 "^  git add root/inputs.env && git commit$" cat "$T/out"
  # What set-inputs.sh writes (it reads the clusters, so the test writes it), then the printed steps.
  printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
    catalogRepoURL=https://github.com/acme/catalog.git catalogRevision=main keycloakOverlay=core hubCertManager=library > "$mine/root/inputs.env"
  finish() { (cd "$mine" && g rm -q root/inputs.yaml && g add root/inputs.env && g commit -q --no-edit && git status --porcelain); }
  t "  ... and those steps finish the merge, leaving nothing else" 0 "^$" finish
fi

echo "update tests: $((total-fails)) ok, $fails failed"; exit "$fails"
