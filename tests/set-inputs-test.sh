#!/usr/bin/env bash
# Tests for scripts/set-inputs.sh and root/inputs.env against a copy of this
# repository's root/, apps/ and hub/catalog/. Offline: set-inputs.sh reads no
# cluster.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
check() { # name condition...
  total=$((total+1)); if "${@:2}"; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1"; fi
}

repo() { # name origin -> a deployment copy
  local d="$T/$1"; mkdir -p "$d"
  cp -R "$SRC/scripts" "$SRC/root" "$SRC/apps" "$SRC/hub" "$d/"
  git -C "$d" init -q && git -C "$d" remote add origin "$2"
  echo "$d"
}
cat_values() { # DIR: the catalog repositories and revisions hub/catalog names, sorted and unique
  yq '.. | select(tag == "!!map") | (.repoURL, .revision, .targetRevision, .sourceRepos[]?) | select(. != null)' \
    "$1"/hub/catalog/*.yaml | grep -vx -- --- | sort -u | tr '\n' ' '
}

d=$(repo ssh git@github.com:acme/deploy.git)
cp "$d/root/kustomization.yaml" "$T/kustomization-before"; cp "$d/root/self.yaml" "$T/self-before"
cp "$d/root/applicationset.yaml" "$T/appset-before"
t "without inputs.env the check names set-inputs.sh" 1 "root/inputs.env is missing: run scripts/set-inputs.sh" \
  "$d/scripts/check-deployment.sh"
t "sets the values and checks" 0 "every repository is an input" \
  "$d/scripts/set-inputs.sh" git@github.com:acme/catalog.git
k="$d/root/inputs.env"
check "deploymentRepoURL from origin, as https" grep -qx 'deploymentRepoURL=https://github.com/acme/deploy.git' "$k"
check "deploymentRevision main" grep -qx 'deploymentRevision=main' "$k"
check "catalogRepoURL from the argument, as https" grep -qx 'catalogRepoURL=https://github.com/acme/catalog.git' "$k"
check "catalogRevision main" grep -qx 'catalogRevision=main' "$k"
check "no tenant IdP input (upstream main has none)" eval '! grep -q "^idp" "$k"'
check "hub/catalog names the catalog and its revision" eval '[ "$(cat_values "$d")" = "https://github.com/acme/catalog.git main " ]'
check "root files untouched" eval 'cmp -s "$T/kustomization-before" "$d/root/kustomization.yaml" && cmp -s "$T/self-before" "$d/root/self.yaml" && cmp -s "$T/appset-before" "$d/root/applicationset.yaml"'

t "a second run keeps the values" 0 "kept +root/inputs.env: catalogRepoURL is already set" \
  "$d/scripts/set-inputs.sh" https://github.com/acme/other.git
check "a second run changes nothing" grep -qx 'catalogRepoURL=https://github.com/acme/catalog.git' "$k"
sed -i.bak 's#^catalogRevision=.*#catalogRevision=release#' "$k"; rm "$k.bak"
t "a catalog revision changed in inputs.env but not in hub/catalog: the check says so" 1 \
  "hub/catalog.*release.*set-inputs.sh" "$d/scripts/check-deployment.sh"
t "a third run keeps the revision you changed and writes it to hub/catalog" 0 "kept +root/inputs.env: catalogRevision is already set" \
  "$d/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... hub/catalog follows it" eval '[ "$(cat_values "$d")" = "https://github.com/acme/catalog.git release " ]'
check "  ... and the root renders it" grep -q 'catalogRevision: release' <(oc kustomize "$d/root")
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=#' "$k"; rm "$k.bak"
t "an empty value is unset" 1 "catalogRepoURL" "$d/scripts/check-deployment.sh"
sed -i.bak '/^catalogRepoURL=/d' "$k"; rm "$k.bak"
t "a missing value fails the render" 1 "catalogRepoURL|oc kustomize" "$d/scripts/check-deployment.sh"

d=$(repo https https://user@github.com/acme/deploy)
t "https origin: credentials dropped, .git added" 0 "deploymentRepoURL = https://github.com/acme/deploy.git$" \
  "$d/scripts/set-inputs.sh" https://github.com/acme/catalog
t "no argument is a usage error" 2 "usage" "$d/scripts/set-inputs.sh"

echo "set-inputs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
