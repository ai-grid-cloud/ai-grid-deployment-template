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
  # The template has no inputs.env; a deployment repository running these tests has its own.
  rm -f "$d/root/inputs.env"
  cat > "$d/clusters.yaml" <<'YAML'
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {api: 'https://api.hub.example.com:6443'}
sites:
  - {name: site-i, api: 'https://api.site-i.example.com:6443'}
  - {name: site-c, api: 'https://api.site-c.example.com:6443'}
YAML
  for n in hub site-i site-c; do mkdir -p "$d/.config/$n"; : > "$d/.config/$n/kubeconfig"; done
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
t "without inputs.env the check names make inputs" 1 "root/inputs.env is missing: run make inputs CATALOG=CATALOG_REPO_URL" \
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

# With no argument, the catalog comes from clusters.yaml's catalog.url (make inputs).
d2=$(repo noarg https://github.com/acme/deploy.git)
t "no argument, page by page: names make inputs CATALOG=" 1 "run make inputs CATALOG=CATALOG_REPO_URL \(page 2\)" \
  "$d2/scripts/set-inputs.sh"
printf 'catalog:\n  url: git@github.com:acme/catalog2.git\n' >> "$d2/clusters.yaml"
t "no argument: reads catalog.url" 0 "every repository is an input" \
  "$d2/scripts/set-inputs.sh"
check "  ... and writes it as https" grep -qx 'catalogRepoURL=https://github.com/acme/catalog2.git' "$d2/root/inputs.env"
# With the private file, the error names its catalog.url.
d3=$(repo private https://github.com/acme/deploy.git); mv "$d3/clusters.yaml" "$d3/.config/clusters.yaml"; chmod 600 "$d3/.config/clusters.yaml"
t "no argument, private file: says where to set it" 1 "set catalog.url in .config/clusters.yaml" \
  "$d3/scripts/set-inputs.sh"
# Given a URL, set-inputs.sh doesn't read the settings, so a bad options: value can't stop it.
d4=$(repo opts https://github.com/acme/deploy.git); printf 'options:\n  GATE_READY_SECONDS: soon\n' >> "$d4/clusters.yaml"
t "a URL argument ignores the options: section" 0 "every repository is an input" \
  "$d4/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "two arguments: usage" 2 "usage: set-inputs.sh \[CATALOG_REPO_URL\]" "$d2/scripts/set-inputs.sh" a b

# keycloakOverlay: core -> default after core was pushed is refused without
# KEYCLOAK_OVERLAY_CHANGE=1. "Pushed" is origin's deploymentRevision as the
# clone's remote-tracking ref has it (git-push.sh updates it); no network.
pushed() { # DIR: commit root/ and record it as origin/main
  git -C "$1" add root && git -C "$1" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm inputs &&
    git -C "$1" update-ref refs/remotes/origin/main HEAD
}
overlay() { sed -i.bak "s#^keycloakOverlay=.*#keycloakOverlay=$2#" "$1/root/inputs.env"; rm "$1/root/inputs.env.bak"; }
ko=$(repo overlay https://github.com/acme/deploy.git)
t "first run with nothing pushed: core, no note" 0 "set +root/inputs.env: keycloakOverlay = core" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... and no keycloakOverlay note" eval '! "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git 2>&1 | grep -q "keycloakOverlay changes"'
kf=$(repo overlay-first https://github.com/acme/deploy.git)
printf 'keycloakOverlay=default\n' > "$kf/root/inputs.env"
t "first run choosing default, nothing pushed: kept" 0 "kept +root/inputs.env: keycloakOverlay is already set" \
  "$kf/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... default stays" grep -qx 'keycloakOverlay=default' "$kf/root/inputs.env"
pushed "$ko"
overlay "$ko" default
t "core pushed, now default: refused" 1 "error: root/inputs.env sets keycloakOverlay=default, but origin.s main has core" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "  ... the message gives the flag and the procedure" 1 "KEYCLOAK_OVERLAY_CHANGE=1.*" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "  ... and links the procedure" 1 "troubleshooting.md#example-organizations-are-missing-after-switching-keycloakoverlay-to-default" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... and leaves default in inputs.env, unchecked" grep -qx 'keycloakOverlay=default' "$ko/root/inputs.env"
t "  ... with KEYCLOAK_OVERLAY_CHANGE=1: goes on and checks" 0 "every repository is an input" \
  env KEYCLOAK_OVERLAY_CHANGE=1 "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "  ... with KEYCLOAK_OVERLAY_CHANGE=1: notes the re-import" 0 "note: keycloakOverlay changes from core to default.*re-import realm saas" \
  env KEYCLOAK_OVERLAY_CHANGE=1 "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "  ... KEYCLOAK_OVERLAY_CHANGE=yes isn't the flag" 1 "origin's main has core" \
  env KEYCLOAK_OVERLAY_CHANGE=yes "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
pushed "$ko"
t "default pushed: no longer a change, goes on" 0 "every repository is an input" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
overlay "$ko" core
t "default pushed, now core: goes on with a note that the examples stay" 0 "note: keycloakOverlay changes from default to core.*keeps the example" \
  "$ko/scripts/set-inputs.sh" https://github.com/acme/catalog.git
# The hub syncs deploymentRevision: only that branch's tracking ref counts.
kr=$(repo overlay-rev https://github.com/acme/deploy.git)
"$kr/scripts/set-inputs.sh" https://github.com/acme/catalog.git >/dev/null
sed -i.bak 's#^deploymentRevision=.*#deploymentRevision=prod#' "$kr/root/inputs.env"; rm "$kr/root/inputs.env.bak"
pushed "$kr"; overlay "$kr" default
t "core only on origin/main, deploymentRevision prod with no tracking ref: not refused" 0 "every repository is an input" \
  "$kr/scripts/set-inputs.sh" https://github.com/acme/catalog.git
git -C "$kr" update-ref refs/remotes/origin/prod refs/remotes/origin/main
t "  ... once origin/prod has core: refused" 1 "origin's prod has core" \
  "$kr/scripts/set-inputs.sh" https://github.com/acme/catalog.git
# A pinned deploymentRevision (a tag or a full SHA) with no tracking ref: the pin is what the hub syncs.
kp=$(repo overlay-pin https://github.com/acme/deploy.git)
"$kp/scripts/set-inputs.sh" https://github.com/acme/catalog.git >/dev/null
git -C "$kp" add root && git -C "$kp" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm core
sha=$(git -C "$kp" rev-parse HEAD); git -C "$kp" tag v1
sed -i.bak "s#^deploymentRevision=.*#deploymentRevision=$sha#" "$kp/root/inputs.env"; rm "$kp/root/inputs.env.bak"
overlay "$kp" default
t "deploymentRevision a full SHA that has core, no tracking ref: refused" 1 "but deploymentRevision $sha has core" \
  "$kp/scripts/set-inputs.sh" https://github.com/acme/catalog.git
sed -i.bak "s#^deploymentRevision=.*#deploymentRevision=v1#" "$kp/root/inputs.env"; rm "$kp/root/inputs.env.bak"
t "deploymentRevision a tag that has core: refused" 1 "but deploymentRevision v1 has core" \
  "$kp/scripts/set-inputs.sh" https://github.com/acme/catalog.git
sed -i.bak "s#^deploymentRevision=.*#deploymentRevision=main#" "$kp/root/inputs.env"; rm "$kp/root/inputs.env.bak"
t "  ... but a local branch with no tracking ref isn't pushed: goes on" 0 "every repository is an input" \
  "$kp/scripts/set-inputs.sh" https://github.com/acme/catalog.git
# An indented key still counts.
ki=$(repo overlay-indent https://github.com/acme/deploy.git)
"$ki/scripts/set-inputs.sh" https://github.com/acme/catalog.git >/dev/null
sed -i.bak 's#^keycloakOverlay=core$#  keycloakOverlay=core#' "$ki/root/inputs.env"; rm "$ki/root/inputs.env.bak"
pushed "$ki"
sed -i.bak 's#^  keycloakOverlay=core$#  keycloakOverlay=default#' "$ki/root/inputs.env"; rm "$ki/root/inputs.env.bak"
t "indented keycloakOverlay, core pushed, now default: refused" 1 "origin's main has core" \
  "$ki/scripts/set-inputs.sh" https://github.com/acme/catalog.git
# A pushed commit without root/inputs.env (the template as cloned) isn't core.
kn=$(repo overlay-none https://github.com/acme/deploy.git)
mkdir -p "$kn/x" && : > "$kn/x/f" && git -C "$kn" add x && git -C "$kn" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm x &&
  git -C "$kn" update-ref refs/remotes/origin/main HEAD
printf 'keycloakOverlay=default\n' > "$kn/root/inputs.env"
t "pushed commit without inputs.env, now default: goes on" 0 "every repository is an input" \
  "$kn/scripts/set-inputs.sh" https://github.com/acme/catalog.git

echo "set-inputs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
