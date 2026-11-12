#!/usr/bin/env bash
# Tests for scripts/empty-catalog.sh (make empty-catalog) against a local bare
# repository as the catalog.
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
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The catalog: a README, a model and a subscription.
seed="$T/seed"; mkdir -p "$seed/clusters/site-b"; echo "# catalog" > "$seed/README.md"
echo model > "$seed/clusters/site-b/model.yaml"; echo sub > "$seed/subscriptions.yaml"
g -C "$seed" init -q && g -C "$seed" add -A && g -C "$seed" commit -qm seed
g clone -q --bare "$seed" "$T/catalog.git"
D="$T/deploy"; mkdir -p "$D/root"; cp -R "$SRC/scripts" "$SRC/Makefile" "$D/"
printf '%s\n' deploymentRepoURL=https://github.com/acme/deploy.git deploymentRevision=main \
  "catalogRepoURL=$T/catalog.git" catalogRevision=main idpIssuerURL=https://idp.example.com/realms/tenants \
  > "$D/root/inputs.env"
files() { g --git-dir="$T/catalog.git" ls-tree -r --name-only main | tr '\n' ' '; }

t "previews what it removes" 0 "clusters/site-b/model.yaml" make -s -C "$D" empty-catalog
t "  ... and keeps README.md" 0 "^ok$" bash -c '! make -s -C "$0" empty-catalog | grep -q "  README.md" && echo ok' "$D"
t "  ... says it's a preview" 0 "CONFIRM=1" make -s -C "$D" empty-catalog
t "  ... and changes nothing" 0 "subscriptions.yaml" files
t "CONFIRM=1 commits and pushes" 0 "catalog: empty for uninstall" bash -c 'make -s -C "$0" empty-catalog CONFIRM=1 >/dev/null && git --git-dir="$1" log -1 --format=%s main' "$D" "$T/catalog.git"
t "  ... leaving only README.md" 0 "^README.md $" files
t "an empty catalog has nothing to remove" 0 "already empty" make -s -C "$D" empty-catalog CONFIRM=1
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=#' "$D/root/inputs.env"; rm "$D/root/inputs.env.bak"
t "no catalogRepoURL names set-inputs.sh" 1 "set-inputs.sh" "$D/scripts/empty-catalog.sh"

echo "empty-catalog tests: $((total-fails)) ok, $fails failed"; exit "$fails"
