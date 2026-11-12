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

# With the real root/, rendered against a local copy of the library (lib2) so
# check-deployment.sh runs offline. Both repositories sit at the same depth, so
# one relative path reaches lib2 from either root.
LIB=$(cd "$SRC" && scripts/library.sh); lib2="$T/lib2"; cp -R "$LIB" "$lib2"
pin() { git -C "$lib2" rev-parse HEAD; }
localize() { # root dir: the library from lib2 at its HEAD
  sed -i.bak -E -e "s#^  - https://github.com/[^ ]+//bootstrap/hub\?ref=[0-9a-f]+#  - ../../lib2/bootstrap/hub#" \
    -e "s/[0-9a-f]{40}/$(pin)/g" "$1/kustomization.yaml"; rm "$1/kustomization.yaml.bak"
}
runl() { (cd "$mine" && TEMPLATE_URL="$tpl" LIBRARY="$lib2" bash scripts/update-from-template.sh); }

# A repository from the template with its inputs set: root/inputs.env is its
# own file, which the template doesn't have.
tpl="$T/tpl-root"; mkdir -p "$tpl"; cp -R "$SRC/scripts" "$SRC/root" "$tpl/"
localize "$tpl/root"; g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm "root"
mine="$T/mine-root"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
  catalogRepoURL=https://github.com/acme/catalog.git catalogRevision=main \
  idpIssuerURL=https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants > "$mine/root/inputs.env"
g -C "$mine" add -A && g -C "$mine" commit -qm "set our names"

# A template commit that moves the library pin merges cleanly.
g -C "$lib2" commit -q --allow-empty -m "new pin"
localize "$tpl/root"; g -C "$tpl" commit -qam "move the pin"
t "a pin move merges with your inputs set, and checks" 0 "every repository is an input" runl
t "  ... takes the new pin" 0 "libraryRevision: $(pin)" cat "$mine/root/kustomization.yaml"
t "  ... keeps your inputs" 0 "^catalogRepoURL=https://github.com/acme/catalog.git$" cat "$mine/root/inputs.env"
t "  ... in the merge commit only" 0 "^Merge the template's main$" g -C "$mine" log -1 --format=%s

# A merge that leaves an input unset says not to push.
sed -i.bak 's#^idpIssuerURL=.*#idpIssuerURL=#' "$mine/root/inputs.env"; rm "$mine/root/inputs.env.bak"
g -C "$mine" commit -qam "unset the issuer"; echo "# note" >> "$tpl/root/self.yaml"; g -C "$tpl" commit -qam "a template change"
t "a failing check says don't push" 1 "DON'T PUSH" runl

# A repository from the template before root/inputs.env (320f038), with its
# values in root/inputs.yaml, which the template has since deleted: the merge
# stops on that file and prints the commands that finish it.
old=$(git -C "$SRC" rev-parse 320f038^)
tpl="$T/tpl-old"; mkdir -p "$tpl/root"; cp -R "$SRC/scripts" "$tpl/"
for f in inputs.yaml kustomization.yaml self.yaml; do git -C "$SRC" show "$old:root/$f" > "$tpl/root/$f"; done
g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm "old root"
mine="$T/mine-old"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/root" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
sed -i.bak -e 's#REQUIRED-deploymentRepoURL#https://github.com/acme/deploy.git#' \
  -e 's#REQUIRED-catalogRepoURL#https://github.com/acme/catalog.git#' \
  -e 's#REQUIRED-idpIssuerURL#https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants#' \
  "$mine/root/inputs.yaml" "$mine/root/self.yaml"; rm "$mine/root/"*.bak
g -C "$mine" commit -qam "set our names"
rm -rf "$tpl/root"; cp -R "$SRC/root" "$tpl/"; rm -f "$tpl/root/inputs.env"; g -C "$tpl" add -A
g -C "$tpl" commit -qm "inputs.env"
t "an old inputs.yaml stops the merge" 1 "conflict in root/inputs.yaml" run
cp "$T/last" "$T/out"
t "  ... prints set-inputs.sh with your catalog URL" 0 "^  scripts/set-inputs.sh https://github.com/acme/catalog.git$" cat "$T/out"
t "  ... then git rm root/inputs.yaml" 0 "^  git rm root/inputs.yaml$" cat "$T/out"
t "  ... then add inputs.env and commit" 0 "^  git add root/inputs.env && git commit$" cat "$T/out"
# What set-inputs.sh writes (it reads the clusters, so the test writes it), then the printed steps.
printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
  catalogRepoURL=https://github.com/acme/catalog.git catalogRevision=main \
  idpIssuerURL=https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants > "$mine/root/inputs.env"
finish() { (cd "$mine" && g rm -q root/inputs.yaml && g add root/inputs.env && g commit -q --no-edit && git status --porcelain); }
t "  ... and those steps finish the merge, leaving nothing else" 0 "^$" finish

echo "update tests: $((total-fails)) ok, $fails failed"; exit "$fails"
