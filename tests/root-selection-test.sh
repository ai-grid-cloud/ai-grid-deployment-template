#!/usr/bin/env bash
# Tests for root/kustomization.yaml's default selection and library pin. Renders
# a copy of root/ offline: the remote base becomes a relative path to a
# `git archive` copy of the library at the root's pin, taken from LIBRARY (any
# clone that has the pinned commit) or else from scripts/library.sh's .library/.
# Nothing is fetched when either one already has the commit.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name cmd...: ok when cmd succeeds
  local name=$1; shift; total=$((total+1))
  if "$@" >"$T/out" 2>&1; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name"; sed 's/^/        /' "$T/out"; fi
}

K="$SRC/root/kustomization.yaml"
PIN=$(sed -n -E 's#^[[:space:]]*- https://github.com/[^ ]+//bootstrap/hub\?ref=([0-9a-f]{40})$#\1#p' "$K")
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "no 40-character pin on the remote base in $K" >&2; exit 1; }
LIBSRC=${LIBRARY:-$(scripts/library.sh)}
mkdir -p "$T/lib"
git -C "$LIBSRC" archive "$PIN" | tar -x -C "$T/lib"

# The root copy, with the library from the archive and a sample inputs.env.
D="$T/deploy"; mkdir -p "$D"; cp -R "$SRC/root" "$D/"
rel=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$T/lib/bootstrap/hub" "$D/root")
sed -i.bak -E "s#^  - https://github.com/[^ ]+//bootstrap/hub\?ref=[0-9a-f]+#  - $rel#" "$D/root/kustomization.yaml"
rm "$D/root/kustomization.yaml.bak"
cat > "$D/root/inputs.env" <<'ENV'
deploymentRepoURL=https://git.example.com/acme/deployment.git
deploymentRevision=main
catalogRepoURL=https://git.example.com/acme/catalog.git
catalogRevision=main
idpIssuerURL=https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants
ENV

render() { oc kustomize "$D/root" > "$T/root.yaml"; }
t "renders: kustomize build root succeeds" render
# The ApplicationSet as JSON: kubectl parses the YAML offline, as clusters.sh does.
AS="$T/appset.json"
KUBECONFIG=/dev/null oc label --local -f "$T/root.yaml" ai-grid.dev/read=true -o json |
  jq -s '[.[] | if .kind == "List" then .items[] else . end | select(.kind == "ApplicationSet")][0] // {}' > "$AS"
files() { jq -er '.spec.generators[0].git.files[].path' "$AS"; }

selects() {
  for p in apps/object-storage/odf/application.yaml bootstrap/hub/components/ai-grid-o11y.yaml \
           apps/ai-grid-usage-logs/application.yaml; do
    files | grep -qxF "$p" || { echo "not selected: $p"; return 1; }
  done
  ! files | grep -qxF apps/object-storage/s4/application.yaml || { echo "S4 still selected"; return 1; }
}
t "selects ODF, o11y and usage logs" selects

no_keycloak() {
  local f; f=$(files) || { echo "no files in generator 0"; return 1; }
  ! grep -qE '^apps/keycloak(-external-services)?/' <<<"$f" || { echo "library Keycloak selected:"; grep keycloak <<<"$f"; return 1; }
}
t "no library Keycloak selected" no_keycloak

odf_kept() {
  jq -e '.spec.generators | length == 3' "$AS" >/dev/null || { echo "want 3 generators"; return 1; }
  jq -e '.spec.generators[1].matrix.generators[0].git.files == [{"path": "apps/odf/application.yaml"}]' "$AS" >/dev/null ||
    { echo "generator 1 isn't ODF"; return 1; }
  jq -e '.spec.generators[1].matrix.generators[0].git.values == .spec.generators[0].git.values' "$AS" >/dev/null ||
    { echo "ODF values differ from generator 0's"; return 1; }
  jq -e '.spec.generators[1].matrix.generators[0].git as $g | .spec.generators[0].git as $z
         | $g.repoURL == $z.repoURL and $g.revision == $z.revision' "$AS" >/dev/null ||
    { echo "ODF repo or revision differs from generator 0's"; return 1; }
  ! grep -q 'REQUIRED-' < <(jq -c '.spec.generators' "$AS") || { echo "REQUIRED- left in the generators"; return 1; }
}
t "ODF generator kept with every input" odf_kept

own_last() {
  jq -e '.spec.generators[-1].git as $g | $g.files == [{"path": "apps/*.yaml"}]
         and $g.repoURL == "https://git.example.com/acme/deployment.git" and $g.revision == "main"
         and $g.values == .spec.generators[0].git.values' "$AS" >/dev/null
}
t "own apps generator is the last, with every input" own_last

one_sha() {
  local s; s=$(jq -r '[.spec.generators[0].git.revision, .spec.generators[0].git.values.libraryRevision,
                        .spec.generators[1].matrix.generators[0].git.revision] | unique | .[]' "$AS")
  [ "$s" = "$PIN" ] || { echo "rendered pins: $s; remote base: $PIN"; return 1; }
  # The three literal places in the file: the remote base, the revision op, values.libraryRevision.
  [ "$(grep -oE '[0-9a-f]{40}' "$K" | sort -u)" = "$PIN" ] || { echo "the file holds more than one SHA"; return 1; }
  [ "$(grep -cE '[0-9a-f]{40}' "$K")" = 3 ] || { echo "want the SHA in exactly three places"; return 1; }
}
t "pinned at one SHA" one_sha

echo "root-selection tests: $((total-fails)) ok, $fails failed"; exit "$fails"
