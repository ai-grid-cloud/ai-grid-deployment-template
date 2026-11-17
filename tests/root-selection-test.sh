#!/usr/bin/env bash
# Tests for the root (root/applicationset.yaml and root/kustomization.yaml): its
# selection, its library pin, and the Applications it generates. Renders a
# copy of root/ offline with a sample inputs.env. The library comes from
# LIBRARY (a checkout at the pin) or else scripts/library.sh's .library/.
#
# With Go installed, it also renders the root's templatePatch for every
# selected component the way the ApplicationSet controller does
# (tests/templatepatch) and checks the generated Applications. Without Go, or
# when the renderer can't be built (no module download), those tests are
# skipped and say so.
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

. scripts/library.sh
PIN=$(library_pin "$SRC" libraryRevision)
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "no 40-character libraryRevision in root/applicationset.yaml" >&2; exit 1; }
LIB=${LIBRARY:-$(scripts/library.sh)}
[ "$(git -C "$LIB" rev-parse HEAD)" = "$PIN" ] || { echo "the library at $LIB isn't at the pin $PIN" >&2; exit 1; }

D="$T/deploy"; mkdir -p "$D"; cp -R "$SRC/root" "$SRC/apps" "$SRC/hub" "$D/"
cat > "$D/root/inputs.env" <<'ENV'
deploymentRepoURL=https://git.example.com/acme/deployment.git
deploymentRevision=main
catalogRepoURL=https://git.example.com/acme/catalog.git
catalogRevision=release
keycloakOverlay=core
hubCertManager=library
ENV

render() { oc kustomize "$D/root" > "$T/root.yaml"; }
t "renders: kustomize build root succeeds" render
AS="$T/appset.json"
KUBECONFIG=/dev/null oc label --local -f "$T/root.yaml" ai-grid.dev/read=true -o json |
  jq -s '[.[] | if .kind == "List" then .items[] else . end | select(.kind == "ApplicationSet")][0] // {}' > "$AS"
files() { jq -er '.spec.generators[0].git.files[].path' "$AS"; }

want_files="apps/gitops-config/application.yaml apps/cert-manager/application.yaml apps/external-secrets/application.yaml apps/acm/application.yaml
apps/grid-bootstrap/application.yaml apps/ai-grid-policies/application.yaml apps/maas-db/application.yaml
apps/limitador-redis/application.yaml apps/keycloak/application.yaml apps/console/application.yaml
apps/ai-grid-spokes/application.yaml apps/argo-registration/application.yaml apps/rhoai/application.yaml
apps/rhoai-prerequisites/application.yaml apps/ai-grid-usage-logs/application.yaml"
selection() {
  diff <(tr ' ' '\n' <<<"$want_files" | grep . | sort) <(files | sort)
}
t "selects the expected library components" selection

not_selected() {
  local p
  for p in apps/acm-models/application.yaml bootstrap/dedicated-hub/application.yaml \
           apps/metallb/application.yaml apps/external-services/application.yaml cluster-config/application.yaml; do
    ! files | grep -qxF "$p" || { echo "selected: $p"; return 1; }
  done
}
t "doesn't select acm-models, dedicated-hub-root, metallb, external-services or cluster-config" not_selected

exist_at_pin() {
  local p
  for p in $(files) apps/odf/application.yaml; do [ -f "$LIB/$p" ] || { echo "not in the library at $PIN: $p"; return 1; }; done
}
t "every selected file exists in the library at the pin" exist_at_pin

generators() {
  jq -e '.spec.generators | length == 3' "$AS" >/dev/null || { echo "want 3 generators"; return 1; }
  jq -e '.spec.generators[1].matrix.generators[0].git.files == [{"path": "apps/odf/application.yaml"}]' "$AS" >/dev/null ||
    { echo "generator 1 isn't ODF"; return 1; }
  jq -e '.spec.generators[2].git as $g | $g.files == [{"path": "apps/*.yaml"}]
         and $g.repoURL == "https://git.example.com/acme/deployment.git" and $g.revision == "main"' "$AS" >/dev/null ||
    { echo "generator 2 isn't this repository's apps/*.yaml"; return 1; }
  jq -e '.spec.generators[0].git.values as $v | .spec.generators[1].matrix.generators[0].git.values == $v
         and .spec.generators[2].git.values == $v' "$AS" >/dev/null || { echo "generators' values differ"; return 1; }
  ! grep -q 'REQUIRED-' < <(jq -c '.spec.generators' "$AS") || { echo "REQUIRED- left in the generators"; return 1; }
}
t "ODF and own-apps generators, every one with every input" generators

one_sha() {
  local s; s=$(jq -r '[.spec.generators[0].git.revision, .spec.generators[0].git.values.libraryRevision,
                        .spec.generators[1].matrix.generators[0].git.revision] | unique | .[]' "$AS")
  [ "$s" = "$PIN" ] || { echo "rendered pins: $s; libraryRevision: $PIN"; return 1; }
  [ "$(grep -cE '[0-9a-f]{40}' "$SRC/root/applicationset.yaml")" = 1 ] || { echo "want the SHA in exactly one place"; return 1; }
  ! grep -qE '[0-9a-f]{40}' "$SRC/root/kustomization.yaml" || { echo "a SHA in kustomization.yaml"; return 1; }
}
t "pinned at one SHA, in one place" one_sha

# --- the generated Applications ----------------------------------------------
TP="$T/templatepatch"
if ! command -v go >/dev/null; then
  echo "   skip generated Applications: no go to build tests/templatepatch"
elif ! (cd "$SRC/tests/templatepatch" && go build -o "$TP" . ) >"$T/build" 2>&1; then
  echo "   skip generated Applications: tests/templatepatch didn't build: $(tail -n1 "$T/build")"
else
  # One request per generated Application: the file's fields as params, with the
  # generator's values, and for ODF a hub's cluster labels (the matrix merge).
  python3 - "$AS" "$LIB" "$D" > "$T/requests.json" <<'PY'
import json, sys, glob, os, subprocess
appset, lib, deploy = sys.argv[1:]
a = json.load(open(appset))
gens = a["spec"]["generators"]
def load(path):
    out = subprocess.run(["yq", "-o=json", ".", path], capture_output=True, text=True, check=True).stdout
    return json.loads(out)
reqs = []
def add(path, values, labels=None):
    p = load(path)
    p["values"] = values
    if labels is not None:
        p.setdefault("metadata", {})["labels"] = labels
    reqs.append({"file": path, "templatePatch": a["spec"]["templatePatch"],
                 "options": a["spec"].get("goTemplateOptions", []), "params": p})
for f in gens[0]["git"]["files"]:
    add(os.path.join(lib, f["path"]), gens[0]["git"]["values"])
odf = gens[1]["matrix"]["generators"][0]["git"]
add(os.path.join(lib, odf["files"][0]["path"]), odf["values"],
    {"apps.open-cluster-management.io/cluster-name": "local-cluster", "openshiftVersion-major-minor": "4.21"})
for f in sorted(glob.glob(os.path.join(deploy, "apps", "*.yaml"))):
    add(f, gens[2]["git"]["values"])
json.dump(reqs, sys.stdout)
PY
  : > "$T/apps.jsonl"
  render_apps() {
    local n i
    n=$(jq length "$T/requests.json")
    for ((i = 0; i < n; i++)); do
      jq -c ".[$i] | {templatePatch, options, params}" "$T/requests.json" > "$T/req.json"
      "$TP" < "$T/req.json" > "$T/patch.yaml" || { echo "templatePatch failed for $(jq -r ".[$i].file" "$T/requests.json")"; return 1; }
      yq -o=json -I=0 '.' "$T/patch.yaml" | jq -c --arg name "$(jq -r ".[$i].params.metadata.name" "$T/requests.json")" \
        '{name: $name, spec: .spec}' >> "$T/apps.jsonl"
    done
  }
  t "templatePatch renders every generated Application" render_apps

  lib_url=$(library_pin "$SRC" libraryRepoURL)
  sources() { jq -c '{name, s: ((.spec.sources // [.spec.source])[])}' "$T/apps.jsonl"; }
  pinned() {
    local bad
    bad=$(sources | jq -r --arg u "${lib_url%.git}" --arg p "$PIN" \
      'select((.s.repoURL | rtrimstr(".git")) == $u and .s.targetRevision != $p) | "\(.name): \(.s.path // .s.ref) at \(.s.targetRevision)"')
    [ -z "$bad" ] || { echo "library sources off the pin:"; echo "$bad"; return 1; }
    [ "$(sources | jq -r --arg u "${lib_url%.git}" 'select((.s.repoURL | rtrimstr(".git")) == $u) | .name' | sort -u | wc -l)" -ge 15 ] ||
      { echo "fewer library-reading Applications than expected"; return 1; }
  }
  t "every library source of every generated Application is at the pin" pinned

  paths_exist() {
    local bad
    bad=$(sources | jq -r --arg u "${lib_url%.git}" 'select((.s.repoURL | rtrimstr(".git")) == $u and .s.path != null) | .s.path' |
      sort -u | while read -r p; do [ -e "$LIB/$p" ] || echo "$p"; done)
    [ -z "$bad" ] || { echo "paths missing at the pin:"; echo "$bad"; return 1; }
  }
  t "every library path the Applications read exists at the pin" paths_exist

  no_tokens() { ! grep -E '@[a-zA-Z]+@|REQUIRED-' "$T/apps.jsonl"; }
  t "no @input@ or REQUIRED- left in the Applications" no_tokens

  app() { jq -c --arg n "$1" 'select(.name == $n) | .spec' "$T/apps.jsonl"; }
  keycloak_core() { [ "$(app keycloak | jq -r .source.path)" = apps/keycloak/overlays/core ]; }
  t "keycloak uses the core profile (no example tenant realms)" keycloak_core
  kc_req() { jq -c --arg o "$1" '[.[] | select(.params.metadata.name == "keycloak")][0] | {templatePatch, options, params}
    | .params.values.keycloakOverlay = $o' "$T/requests.json"; }
  keycloak_default() { kc_req default | "$TP" | yq -o=json '.spec.source.path' | grep -qx '"apps/keycloak/overlays/default"'; }
  t "keycloakOverlay=default: the library's examples (test deployments)" keycloak_default
  keycloak_bad() { ! kc_req examples | "$TP" >/dev/null 2>&1; }
  t "any other keycloakOverlay fails the Application" keycloak_bad
  cm_req() { jq -c --arg o "$1" '[.[] | select(.params.metadata.name == "cert-manager")][0] | {templatePatch, options, params}
    | .params.values.hubCertManager = $o' "$T/requests.json"; }
  cm_library() { [ "$(app cert-manager | jq -r '.source.path')" = apps/cert-manager/manifests ] && [ "$(app cert-manager | jq -r '.source.directory')" = null ]; }
  t "hubCertManager=library: the library's cert-manager, as upstream's root" cm_library
  cm_platform() { cm_req platform | "$TP" | yq -o=json '.spec.source.directory.include' | grep -qx '"{platform-cert-manager}"'; }
  t "hubCertManager=platform: the Application selects no file" cm_platform
  cm_site() { cm_req site | "$TP" | yq -o=json '.spec.source.directory.include' | grep -qx '"{platform-cert-manager}"'; }
  t "hubCertManager=site: the same (OpenShift AI's chart owns it)" cm_site
  cm_bad() { ! cm_req yes | "$TP" >/dev/null 2>&1; }
  t "any other hubCertManager fails the Application" cm_bad
  console_catalog() {
    app console | jq -e '[.sources[] | select(.helm) | .helm.valuesObject.backend.git] | .[0]
      | .url == "https://git.example.com/acme/catalog.git" and .branch == "release"' >/dev/null
  }
  t "console writes to the catalog input" console_catalog
  grid_ca() {
    app grid-bootstrap | jq -e '[.sources[] | select(.helm) | .helm.parameters[]] | any(.name == "external.certManager.ca.mode" and .value == "Generate")' >/dev/null
  }
  t "grid-bootstrap generates the grid CA" grid_ca
  odf_version() { app odf | jq -e '.source.helm.parameters == [{"name": "openshift.version", "value": "4.21"}]' >/dev/null; }
  t "odf follows the hub's OpenShift version" odf_version
  own_apps() {
    app catalog | jq -e '.source.repoURL == "https://git.example.com/acme/deployment.git" and .source.path == "hub/catalog"' >/dev/null &&
    app ai-grid-o11y | jq -e --arg p "$PIN" '.sources[1].targetRevision == $p and .sources[1].path == "charts/ai-grid-o11y"' >/dev/null
  }
  t "own apps: catalog from this repository, ai-grid-o11y from the library at the pin" own_apps

  # Not a failure: what the pin can't reach. Listed for docs/upstream-main-limits.md.
  sources | jq -r --arg u "${lib_url%.git}" 'select((.s.repoURL | rtrimstr(".git")) != $u and (.s.repoURL | test("ai-grid-cloud/ai-grid-provider-console|git.example.com") | not))
    | "   note \(.name) reads \(.s.repoURL) at \(.s.targetRevision) (not pinned by the root)"' | sort -u
fi

echo "root-selection tests: $((total-fails)) ok, $fails failed"; exit "$fails"
