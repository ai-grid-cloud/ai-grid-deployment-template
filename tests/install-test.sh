#!/usr/bin/env bash
# Tests for scripts/install.sh (make install), the hub phase. Every script it
# calls is a fake that logs its name and arguments to $STUB_DIR/calls.log and
# answers from files: NAME.rc for its exit status, NAME.out for its output.
# A stub oc answers from files in $STUB_DIR, as in tests/status-test.sh.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SENTINEL='sha256~SENTINEL_TOKEN_VALUE'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GATE_INTERVAL=0
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; calls:)"; cat "$W/calls.log" 2>/dev/null; echo "(output:)"; echo "$out"; fi
}

# The stub oc logs its arguments and answers from files in $STUB_DIR; a missing
# file is NotFound. In deployment-root, @HEAD@ stands for the repository's HEAD.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; a=" $* "
ans() { # NAME: NAME.err is an oc error, a missing NAME is NotFound
  [ ! -f "$d/$1.err" ] || { cat "$d/$1.err" >&2; exit 1; }
  [ -f "$d/$1" ] || { echo "Error from server (NotFound): $1" >&2; exit 1; }; cat "$d/$1"; }
case "$a" in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io deployment-root "*)
    ans deployment-root >/dev/null || exit 1
    sed "s/@HEAD@/$(git -C "$REPO" rev-parse HEAD)/" "$d/deployment-root" ;;
  *" get applications.argoproj.io "*) ans apps.json ;;
  *" get multiclusterhub "*) ans mch.json ;;
  *" get secret ai-grid-backend-git "*) ans console-secret ;;
  *" get secret rhoai-quay-pull-secret -n rhoai-prerequisites "*) ans hub-pull-secret ;;
  *" get managedclusters.cluster.open-cluster-management.io "*) set -- $*; ans "mc-$3.json" ;;
  *" get placements."*) echo '{"items":[]}' ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

# A fake for each script install.sh calls. bootstrap-hub.sh creates
# deployment-root, Synced at HEAD, and the hub pull secret; git-push.sh
# commits, as a push would, unless $STUB_DIR/nothing-to-push exists.
# site-check.sh NAME exits with $STUB_DIR/site-check-NAME.rc when it exists;
# import-site.sh NAME creates ManagedCluster NAME, joined and available.
fake() { # NAME [EXTRA]
  cat > "$D/scripts/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "\$STUB_DIR/calls.log"
${2:-}
[ ! -f "\$STUB_DIR/$1.out" ] || cat "\$STUB_DIR/$1.out"
exit \$(cat "\$STUB_DIR/$1.rc" 2>/dev/null || echo 0)
EOF
  chmod +x "$D/scripts/$1"
}
mc_available='{"status":{"conditions":[{"type":"ManagedClusterJoined","status":"True"},{"type":"ManagedClusterConditionAvailable","status":"True"}]}}'
root_at_head='{"metadata":{"name":"deployment-root"},"status":{"sync":{"status":"Synced","revision":"@HEAD@"},"health":{"status":"Healthy"}}}'

setup() { # NAME: a deployment repository $D and a stub directory $W, for one case
  D="$T/$1/repo" W="$T/$1/stub"; mkdir -p "$W" "$D/.config"
  cp -R "$SRC/scripts" "$D/"
  for s in login.sh set-library.sh set-inputs.sh check-deployment.sh empty-catalog.sh \
      install-report.sh provider-admin.sh; do fake "$s"; done
  fake ready-check.sh '[ ! -f "$STUB_DIR/ready-check.sh.rc" ] || { echo "OK   hub Applications"; echo "FAIL site site-a: not available"; echo "Not ready: see FAIL above."; }'
  fake create-console-secrets.sh '[ -z "${CATALOG_TOKEN_FILE:-}" ] || cat "$CATALOG_TOKEN_FILE" > "$STUB_DIR/catalog-token-seen"'
  fake git-push.sh 'cat "$DEPLOYMENT_TOKEN_FILE" > "$STUB_DIR/deployment-token-seen"; echo "$DEPLOYMENT_TOKEN_FILE" > "$STUB_DIR/deployment-token-path"
    if [ -f "$STUB_DIR/nothing-to-push" ]; then echo "nothing to push"
    else git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m pushed; fi'
  fake site-check.sh '[ ! -f "$STUB_DIR/site-check-$1.out" ] || cat "$STUB_DIR/site-check-$1.out"
    [ ! -f "$STUB_DIR/site-check-$1.rc" ] || exit "$(cat "$STUB_DIR/site-check-$1.rc")"'
  fake import-site.sh "[ -f \"\$STUB_DIR/mc-\$1.json\" ] || printf '%s' '$mc_available' > \"\$STUB_DIR/mc-\$1.json\""
  fake bootstrap-hub.sh "printf '%s' '$root_at_head' > \"\$STUB_DIR/deployment-root\"; echo '{}' > \"\$STUB_DIR/hub-pull-secret\""
  # sites: comes last, so a test can append a site.
  cat > "$D/clusters.yaml" <<'YAML'
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {name: hub, api: "https://api.hub.example.com:6443"}
repositories:
  catalog: https://github.com/acme/catalog.git
  library: ""
options:
sites:
- {name: site-a, role: combined, location: us-east, api: "https://api.site-a.example.com:6443"}
YAML
  for f in deployment-token catalog-token; do printf '%s\n' "$SENTINEL" > "$D/.config/$f"; done
  printf '{"auths":{"quay.io/rhoai":{"auth":"%s"}}}\n' "$SENTINEL" > "$D/.config/quay-auth.json"
  mkdir -p "$D/.config/hub"; printf "users:\n- user: {token: '%s'}\n" "$SENTINEL" > "$D/.config/hub/kubeconfig"
  mkdir -p "$D/root"; printf '%s\n' deploymentRevision=main 'catalogRepoURL=git@github.com:acme/catalog' > "$D/root/inputs.env"
  g -C "$D" init -q && g -C "$D" add clusters.yaml root && g -C "$D" commit -qm seed
  echo '{"items":[{"status":{"phase":"Running"}}]}' > "$W/mch.json"
  echo '{"items":[{"metadata":{"name":"acm"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}' > "$W/apps.json"
  : > "$W/calls.log"; : > "$W/argv.log"
}
opt() { # KEY VALUE: adds an options: entry to clusters.yaml
  sed -i.bak "s#^options:\$#options:\\
  $1: $2#" "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
}
run() { # [ARG...]: runs install.sh in $D; sets rc and out, and keeps all output for the leak check
  out=$(cd "$D" && env PATH="$T/bin:$PATH" STUB_DIR="$W" REPO="$D" scripts/install.sh "$@" 2>"$W/stderr") && rc=0 || rc=$?
  out+=$'\n'"$(cat "$W/stderr")"
  all_out+="$out"$'\n'
  [ ! -d "$D/.install" ] || all_out+="$(cat "$D/.install"/* 2>/dev/null)"$'\n'
}
calls() { sed 's/ *$//' "$W/calls.log" | tr '\n' ';'; }
all_out=""

setup fresh; run
t "fresh: runs every hub step in order" eval '[ "$rc" = 0 ] &&
  [ "$(calls)" = "login.sh --non-interactive;set-inputs.sh https://github.com/acme/catalog.git;git-push.sh install: inputs and library pin root/ tenant-idp/manifests/settings.yaml;empty-catalog.sh --check;bootstrap-hub.sh;create-console-secrets.sh;site-check.sh site-a;import-site.sh site-a --yes;provider-admin.sh;ready-check.sh;" ]'

t "end: provider-admin then ready-check, then the outputs line" eval '[ "$rc" = 0 ] &&
  [ "$(grep -E "^(== (provider-admin|ready)|gate (hub-apps-final|ready))" <<<"$out" | sed -E "s/ after .*//" | tr "\n" ";")" = "gate hub-apps-final: passed;== provider-admin;== ready;gate ready: passed;" ] &&
  [ "$(grep . <<<"$out" | tail -n 1)" = "Installed. Outputs: .install/outputs.json" ]'

setup readyfail
echo 1 > "$W/ready-check.sh.rc"
GATE_READY_SECONDS=0 run
t "ready check fails: its FAIL lines, the report, exit 1" eval '[ "$rc" = 1 ] &&
  grep -q "^gate ready: FAILED after 0s: 1 FAIL; first: FAIL site site-a: not available" <<<"$out" &&
  grep -qx "FAIL site site-a: not available" <<<"$out" && grep -qx "install-report.sh ready" "$W/calls.log" &&
  grep -qx "make install stopped at ready. Fix the cause, then run make install again." <<<"$out" &&
  [ "$(cat "$D/.install/failed-gate")" = ready ] && ! grep -q "^Installed" <<<"$out"'

setup hubonly; run --hub-only
t "--hub-only: no sites, no provider-admin, no ready check" eval '[ "$rc" = 0 ] &&
  ! grep -qE "^(site-check|import-site|provider-admin|ready-check)" "$W/calls.log" &&
  ! grep -q "^Installed" <<<"$out" && grep -q "hub only" <<<"$out"'

setup rerun
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/console-secret"; echo '{}' > "$W/hub-pull-secret"
run
t "rerun: every step already done; console-secrets always reruns" eval '[ "$rc" = 0 ] && ! grep -q "^bootstrap-hub" "$W/calls.log" &&
  grep -q "^create-console-secrets.sh" "$W/calls.log" &&
  grep -q "^== bootstrap" <<<"$out"'

setup required
sed -i.bak 's#^  catalog: .*#  catalog: REQUIRED-catalogRepoURL#' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
run
t "REQUIRED- left in clusters.yaml: stops before any cluster call" eval '[ "$rc" = 1 ] &&
  grep -q "REQUIRED-catalogRepoURL" <<<"$out" && [ ! -s "$W/calls.log" ] && [ ! -s "$W/argv.log" ]'

setup gatefail
echo '{"items":[{"status":{"phase":"Installing"}}]}' > "$W/mch.json"
GATE_MCH_SECONDS=0 run
t "gate fails: report and exit 1" eval '[ "$rc" = 1 ] && grep -q "^install-report.sh" "$W/calls.log" &&
  grep -qx "make install stopped at hub-acm. Fix the cause, then run make install again." <<<"$out" &&
  [ "$(cat "$D/.install/failed-gate")" = hub-acm ] && ! grep -q "^create-console-secrets" "$W/calls.log"'

setup catalog
echo 1 > "$W/empty-catalog.sh.rc"
echo "error: the catalog https://github.com/acme/catalog.git (main) isn't empty" > "$W/empty-catalog.sh.out"
run
t "catalog not empty: stops" eval '[ "$rc" = 1 ] && grep -q "isn.t empty" <<<"$out" &&
  grep -q "stopped at catalog" <<<"$out" && ! grep -q "^bootstrap-hub" "$W/calls.log"'

setup partial
printf '%s' "$root_at_head" > "$W/deployment-root"
run
t "partial bootstrap: deployment-root but no hub pull secret reruns bootstrap" eval '[ "$rc" = 0 ] &&
  grep -q "^bootstrap-hub.sh" "$W/calls.log"'

setup catalogurl
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=https://github.com/acme/other.git#' "$D/root/inputs.env"; rm "$D/root/inputs.env.bak"
run
t "changed CATALOG_REPO_URL: stops and names both" eval '[ "$rc" = 1 ] &&
  grep -q "https://github.com/acme/other.git" <<<"$out" && grep -q "https://github.com/acme/catalog.git" <<<"$out" &&
  grep -q "root/inputs.env" <<<"$out" && ! grep -q "^git-push.sh" "$W/calls.log"'

setup quoted
sed -i.bak 's%^  catalog: .*%  catalog: "https://github.com/acme/catalog.git #frag" # a comment%' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=https://github.com/acme/catalog.git \#frag#' "$D/root/inputs.env"; rm "$D/root/inputs.env.bak"
run
t "clusters.yaml: a quoted value keeps its #" eval '[ "$rc" = 0 ] &&
  grep -qF "set-inputs.sh https://github.com/acme/catalog.git #frag" "$W/calls.log"'

setup gatevalue
opt GATE_ROOT_SECONDS 5x
run
t "clusters.yaml: GATE_ROOT_SECONDS: 5x stops" eval '[ "$rc" = 1 ] && grep -q "GATE_ROOT_SECONDS" <<<"$out" && [ ! -s "$W/calls.log" ]'

setup nocatalog
sed -i.bak 's#^  catalog: .*#  catalog: ""#' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
run
t "no catalog in clusters.yaml: stops and names the key" eval '[ "$rc" = 1 ] && [ ! -s "$W/calls.log" ] &&
  grep -q "set repositories.catalog in clusters.yaml" <<<"$out"'

# The private file: secrets from .config/clusters.yaml, the environment over it.
private() { # moves $D's clusters.yaml to .config/ with a secrets block, mode 600; drops the legacy files
  mv "$D/clusters.yaml" "$D/.config/clusters.yaml"; g -C "$D" rm -q --cached clusters.yaml; g -C "$D" commit -qm private
  cat >> "$D/.config/clusters.yaml" <<YAML
github: {deploymentToken: "$SENTINEL-deploy", catalogToken: "$SENTINEL-catalog"}
quay: {username: "rhoai+robot", password: "$SENTINEL-quay"}
YAML
  chmod 600 "$D/.config/clusters.yaml"; rm -f "$D/.config/deployment-token" "$D/.config/catalog-token" "$D/.config/quay-auth.json"
}
setup private; private
run
t "private file: installs" eval '[ "$rc" = 0 ]'
t "  ... git-push gets the deployment token in a file" grep -qx "$SENTINEL-deploy" "$W/deployment-token-seen"
t "  ... console-secrets gets the catalog token in a file" grep -qx "$SENTINEL-catalog" "$W/catalog-token-seen"
t "  ... the token file is .config/generated/deployment-token, mode 600" bash -c '[ "$(cat "$0/deployment-token-path")" = "$1/.config/generated/deployment-token" ] &&
  [ "$(stat -f %Lp "$1/.config/generated/deployment-token" 2>/dev/null || stat -c %a "$1/.config/generated/deployment-token")" = 600 ]' "$W" "$D"
t "  ... .config/generated/quay-auth.json built for quay.io/rhoai, mode 600" bash -c '
  [ "$(jq -r ".auths[\"quay.io/rhoai\"].auth" "$0/.config/generated/quay-auth.json" | base64 -d)" = "rhoai+robot:$1-quay" ] &&
  [ "$(stat -f %Lp "$0/.config/generated/quay-auth.json" 2>/dev/null || stat -c %a "$0/.config/generated/quay-auth.json")" = 600 ]' "$D" "$SENTINEL"

setup privateenv; private
AI_GRID_DEPLOYMENT_TOKEN="$SENTINEL-env" run
t "AI_GRID_DEPLOYMENT_TOKEN beats the file" grep -qx "$SENTINEL-env" "$W/deployment-token-seen"

setup privatemissing; private
sed -i.bak '/^github:/d' "$D/.config/clusters.yaml"; rm "$D/.config/clusters.yaml.bak"
run
t "no deployment token anywhere: stops before any cluster call, naming the key" eval '[ "$rc" = 1 ] && [ ! -s "$W/calls.log" ] &&
  grep -q "github.deploymentToken in .config/clusters.yaml" <<<"$out"'

setup droppedoption; opt DEPLOYMENT_TOKEN_FILE .config/deployment-token
run
t "a dropped *_FILE option: stops with where it goes now" eval '[ "$rc" = 1 ] && grep -q "options.DEPLOYMENT_TOKEN_FILE is no longer read: put the token in github.deploymentToken" <<<"$out"'

setup oldenv
printf 'CATALOG_REPO_URL=https://github.com/acme/catalog.git\n' > "$D/install.env"
run
t "an install.env stops, with the migration" eval '[ "$rc" = 1 ] && [ ! -s "$W/calls.log" ] &&
  grep -q "install.env is no longer read: move its settings into clusters.yaml" <<<"$out"'

setup envfallback
GATE_ROOT_SECONDS=5x run
t "a setting the file leaves out comes from the environment" eval '[ "$rc" = 1 ] && grep -q "GATE_ROOT_SECONDS" <<<"$out"'

setup filewins
opt GATE_ROOT_SECONDS 600; g -C "$D" commit -qam gate
GATE_ROOT_SECONDS=5x run
t "the file's setting wins over the environment" eval '[ "$rc" = 0 ]'

setup ocerror
printf '%s' "$root_at_head" > "$W/deployment-root"
echo "error: You must be logged in to the server (Unauthorized)" > "$W/hub-pull-secret.err"
run
t "oc error: stops with the make install line" eval '[ "$rc" = 1 ] && grep -q "Unauthorized" <<<"$out" &&
  grep -qx "make install stopped at bootstrap. Fix the cause, then run make install again." <<<"$out"'

setup quaylogin
printf '{"auths":{"quay.io":{"auth":"%s"}}}\n' "$SENTINEL" > "$D/.config/quay-auth.json"
run
t "general quay.io login without ALLOW_GENERIC_LOGIN: stops before the inputs push" eval '[ "$rc" = 1 ] &&
  grep -qF "no quay.io/rhoai login in $D/.config/quay-auth.json; add a robot token for quay.io/rhoai, or set ALLOW_GENERIC_LOGIN=1 to use the general quay.io login" <<<"$out" &&
  ! grep -q "^git-push.sh" "$W/calls.log" && [ ! -s "$W/argv.log" ]'

setup quaygeneric
printf '{"auths":{"quay.io":{"auth":"%s"}}}\n' "$SENTINEL" > "$D/.config/quay-auth.json"
opt ALLOW_GENERIC_LOGIN 1; g -C "$D" commit -qam generic
run
t "general quay.io login with ALLOW_GENERIC_LOGIN=1: installs" eval '[ "$rc" = 0 ] && grep -q "^bootstrap-hub.sh" "$W/calls.log"'

setup branch
g -C "$D" checkout -qb feature
run
t "checkout not on deploymentRevision: stops with both names" eval '[ "$rc" = 1 ] &&
  grep -q "feature" <<<"$out" && grep -q "main" <<<"$out" && [ ! -s "$W/calls.log" ]'

setup nopush
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/console-secret"; echo '{}' > "$W/hub-pull-secret"
: > "$W/nothing-to-push"
before=$(git -C "$D" rev-parse HEAD)
GATE_ROOT_SECONDS=0 run
t "rerun, nothing to push: no new commit, hub-root gates on HEAD" eval '[ "$rc" = 0 ] &&
  grep -q "nothing to push" <<<"$out" && [ "$(git -C "$D" rev-parse HEAD)" = "$before" ] &&
  grep -q "gate hub-root: passed" <<<"$out"'

two_sites() { # adds site-b, an inference site, to clusters.yaml
  printf '%s\n' '- {name: site-b, role: inference, location: us-west, api: "https://api.site-b.example.com:6443"}' >> "$D/clusters.yaml"
  g -C "$D" commit -qam "site-b"
}

setup twosites; two_sites; run
t "two sites: check, import and gate each, in order" eval '[ "$rc" = 0 ] &&
  [ "$(grep -E "^(site-check|import-site)" "$W/calls.log" | sed "s/ *\$//" | tr "\n" ";")" = "site-check.sh site-a;import-site.sh site-a --yes;site-check.sh site-b;import-site.sh site-b --yes;" ] &&
  [ "$(grep -E "^(== site |gate (site-|hub-apps-final))" <<<"$out" | sed -E "s/ after .*//" | tr "\n" ";")" = "== site site-a;gate site-site-a-import: passed;== site site-b;gate site-site-b-import: passed;gate hub-apps-final: passed;" ] &&
  grep -qx "Installed. Outputs: .install/outputs.json" <<<"$out"'

setup siterun
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/console-secret"; echo '{}' > "$W/hub-pull-secret"
printf '%s' "$mc_available" > "$W/mc-site-a.json"
echo "site-a is already imported; nothing to do." > "$W/import-site.sh.out"
GATE_SITE_IMPORT_SECONDS=0 run
t "rerun: site already imported" eval '[ "$rc" = 0 ] && grep -q "already imported" <<<"$out" &&
  grep -q "gate site-site-a-import: passed" <<<"$out" && grep -q "gate hub-apps-final: passed" <<<"$out"'

setup sitecheck; two_sites
echo 1 > "$W/site-check-site-b.rc"
echo "FOUND    previous AI Grid install            namespace ai-grid-site" > "$W/site-check-site-b.out"
run
t "site-check fails: stops and names the site" eval '[ "$rc" = 1 ] && grep -q "FOUND    previous AI Grid install" <<<"$out" &&
  grep -qx "make install stopped at site site-b. Fix the cause, then run make install again." <<<"$out" &&
  grep -q "^import-site.sh site-a --yes" "$W/calls.log" && ! grep -q "^import-site.sh site-b" "$W/calls.log" &&
  ! grep -q "hub-apps-final" <<<"$out"'

set_role() { # SITE ROLE: changes the site's role in clusters.yaml
  sed -i.bak "s/name: $1, role: [a-z]*/name: $1, role: $2/" "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
  g -C "$D" commit -qam "role $1 $2"
}

setup ingress; set_role site-a ingress
run
t "an ingress site: no certificate step, no ClusterIssuer read, imported" eval '[ "$rc" = 0 ] &&
  ! grep -q "install: site files" "$W/calls.log" && ! grep -q "clusterissuers" "$W/argv.log" &&
  ! grep -q "^== site-files" <<<"$out" && grep -q "^import-site.sh site-a --yes" "$W/calls.log"'

setup issuerkey
sed -i.bak 's/name: site-a, role: combined,/name: site-a, issuer: acme-prod, role: combined,/' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
g -C "$D" commit -qam issuer
run
t "an issuer: site key is an unknown key now" eval '[ "$rc" = 1 ] && grep -q "unknown keys (typos?): sites\[0\].issuer" <<<"$out" && [ ! -s "$W/calls.log" ]'

t "no token value in any output" eval '[ -n "$all_out" ] && ! grep -qF "$SENTINEL" <<<"$all_out" &&
  ! grep -rqF "$SENTINEL" "$T"/*/repo/.install "$T"/*/stub/calls.log "$T"/*/stub/argv.log 2>/dev/null'

echo "install tests: $((total-fails)) ok, $fails failed"; exit "$fails"
