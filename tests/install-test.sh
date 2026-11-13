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
  *" get clusterissuers.cert-manager.io "*) ans "issuers-$(basename "$(dirname "$KUBECONFIG")").json" ;;
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
      create-console-secrets.sh install-report.sh add-site.sh; do fake "$s"; done
  fake git-push.sh 'if [ -f "$STUB_DIR/nothing-to-push" ]; then echo "nothing to push"
    else git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m pushed; fi'
  fake site-check.sh '[ ! -f "$STUB_DIR/site-check-$1.out" ] || cat "$STUB_DIR/site-check-$1.out"
    [ ! -f "$STUB_DIR/site-check-$1.rc" ] || exit "$(cat "$STUB_DIR/site-check-$1.rc")"'
  fake import-site.sh "[ -f \"\$STUB_DIR/mc-\$1.json\" ] || printf '%s' '$mc_available' > \"\$STUB_DIR/mc-\$1.json\""
  fake bootstrap-hub.sh "printf '%s' '$root_at_head' > \"\$STUB_DIR/deployment-root\"; echo '{}' > \"\$STUB_DIR/hub-pull-secret\""
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n- {name: site-a, role: combined, location: us-east, api: "https://api.site-a.example.com:6443"}\n' > "$D/clusters.yaml"
  cat > "$D/install.env" <<'EOF'
# The install's choices.
LIBRARY_REVISION=
CATALOG_REPO_URL=https://github.com/acme/catalog.git
DEPLOYMENT_TOKEN_FILE=.config/deployment-token
CATALOG_TOKEN_FILE=.config/catalog-token
QUAY_AUTH_FILE=.config/quay-auth.json
# KEYCLOAK=install
EOF
  for f in deployment-token catalog-token; do printf '%s\n' "$SENTINEL" > "$D/.config/$f"; done
  printf '{"auths":{"quay.io/rhoai":{"auth":"%s"}}}\n' "$SENTINEL" > "$D/.config/quay-auth.json"
  mkdir -p "$D/.config/hub"; printf "users:\n- user: {token: '%s'}\n" "$SENTINEL" > "$D/.config/hub/kubeconfig"
  mkdir -p "$D/root"; printf '%s\n' deploymentRevision=main 'catalogRepoURL=git@github.com:acme/catalog' > "$D/root/inputs.env"
  g -C "$D" init -q && g -C "$D" add clusters.yaml install.env root && g -C "$D" commit -qm seed
  echo '{"items":[{"status":{"phase":"Running"}}]}' > "$W/mch.json"
  echo '{"items":[{"metadata":{"name":"acm"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}' > "$W/apps.json"
  issuers site-a dns01:letsencrypt-dns
  : > "$W/calls.log"; : > "$W/argv.log"
}
issuers() { # SITE [SOLVER:NAME...]: the site's ClusterIssuers, as its oc answers them
  local site=$1 items="" i; shift
  for i in "$@"; do items+="${items:+,}{\"metadata\":{\"name\":\"${i#*:}\"},\"spec\":{\"acme\":{\"solvers\":[{\"${i%%:*}\":{}}]}}}"; done
  printf '{"items":[%s]}\n' "$items" > "$W/issuers-$site.json"
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
  [ "$(calls)" = "login.sh --non-interactive;set-inputs.sh https://github.com/acme/catalog.git;git-push.sh install: inputs and library pin root/ tenant-idp/manifests/settings.yaml;empty-catalog.sh --check;bootstrap-hub.sh;create-console-secrets.sh;add-site.sh site-a;git-push.sh install: site files apps/ sites/ values/clusters/;site-check.sh site-a;import-site.sh site-a --yes;" ]'

setup rerun
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/console-secret"; echo '{}' > "$W/hub-pull-secret"
run
t "rerun: every step already done" eval '[ "$rc" = 0 ] && ! grep -qE "^(bootstrap-hub|create-console-secrets)" "$W/calls.log" &&
  grep -q "^== bootstrap" <<<"$out"'

setup required
sed -i.bak 's#^CATALOG_REPO_URL=.*#CATALOG_REPO_URL=REQUIRED-catalogRepoURL#' "$D/install.env"; rm "$D/install.env.bak"
run
t "REQUIRED- left in install.env: stops before any cluster call" eval '[ "$rc" = 1 ] &&
  grep -q "CATALOG_REPO_URL" <<<"$out" && [ ! -s "$W/calls.log" ] && [ ! -s "$W/argv.log" ]'

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
printf '%s\n' 'CATALOG_REPO_URL="https://github.com/acme/catalog.git #frag" # a comment' >> "$D/install.env"
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=https://github.com/acme/catalog.git \#frag#' "$D/root/inputs.env"; rm "$D/root/inputs.env.bak"
run
t "install.env: a quoted value keeps its #" eval '[ "$rc" = 0 ] &&
  grep -qF "set-inputs.sh https://github.com/acme/catalog.git #frag" "$W/calls.log"'

setup gatevalue
echo 'GATE_ROOT_SECONDS=5x' >> "$D/install.env"
run
t "install.env: GATE_ROOT_SECONDS=5x stops" eval '[ "$rc" = 1 ] && grep -q "GATE_ROOT_SECONDS" <<<"$out" && [ ! -s "$W/calls.log" ]'

setup ocerror
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/hub-pull-secret"
echo "error: You must be logged in to the server (Unauthorized)" > "$W/console-secret.err"
run
t "oc error: stops with the make install line" eval '[ "$rc" = 1 ] && grep -q "Unauthorized" <<<"$out" &&
  grep -qx "make install stopped at console-secrets. Fix the cause, then run make install again." <<<"$out"'

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
  grep -q "make install: done" <<<"$out"'

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

setup noissuer; set_role site-a ingress
issuers site-a http01:letsencrypt-http
run
t "ingress site without DNS-01 issuer: stops and names it" eval '[ "$rc" = 1 ] &&
  grep -qF "site-a (ingress) has no DNS-01 ClusterIssuer for its MaaS certificate; add one, or give it role inference." <<<"$out" &&
  grep -qx "make install stopped at site-files. Fix the cause, then run make install again." <<<"$out" &&
  ! grep -qE "^(add-site|import-site)" "$W/calls.log" && ! grep -q "install: site files" "$W/calls.log"'

setup inference; set_role site-a inference
rm "$W/issuers-site-a.json"
run
t "inference site needs none" eval '[ "$rc" = 0 ] && ! grep -q "^add-site" "$W/calls.log" &&
  ! grep -q "install: site files" "$W/calls.log" && ! grep -q "clusterissuers" "$W/argv.log" &&
  grep -q "^import-site.sh site-a --yes" "$W/calls.log"'

setup issuerset
issuers site-a dns01:acme-staging dns01:acme-prod
echo 'SITE_ISSUER_SITE_A=acme-prod' >> "$D/install.env"; g -C "$D" commit -qam issuer
run
t "two DNS-01 issuers and SITE_ISSUER_ set: passes it" eval '[ "$rc" = 0 ] &&
  grep -qx "add-site.sh site-a acme-prod" "$W/calls.log"'

setup issuerunset
issuers site-a dns01:acme-staging dns01:acme-prod
run
t "two issuers and none chosen: stops and lists them" eval '[ "$rc" = 1 ] &&
  grep -q "acme-staging" <<<"$out" && grep -q "acme-prod" <<<"$out" && grep -q "SITE_ISSUER_SITE_A" <<<"$out" &&
  grep -q "stopped at site-files" <<<"$out" && ! grep -qE "^(add-site|import-site)" "$W/calls.log"'

setup sitefiles; two_sites
printf '%s\n' '- {name: site-c, role: ingress, location: eu, api: "https://api.site-c.example.com:6443"}' >> "$D/clusters.yaml"
g -C "$D" commit -qam site-c
issuers site-c dns01:other
run
t "site files pushed once, then the root gate" eval '[ "$rc" = 0 ] &&
  [ "$(grep -E "^(add-site|git-push.sh install: site|site-check)" "$W/calls.log" | sed "s/ *\$//" | tr "\n" ";")" = "add-site.sh site-a;add-site.sh site-c;git-push.sh install: site files apps/ sites/ values/clusters/;site-check.sh site-a;site-check.sh site-b;site-check.sh site-c;" ] &&
  [ "$(sed -n "/^== site-files/,/^== site site-a/p" <<<"$out" | grep -c "gate hub-root: passed")" = 1 ]'

t "no token value in any output" eval '[ -n "$all_out" ] && ! grep -qF "$SENTINEL" <<<"$all_out" &&
  ! grep -rqF "$SENTINEL" "$T"/*/repo/.install "$T"/*/stub/calls.log "$T"/*/stub/argv.log 2>/dev/null'

echo "install tests: $((total-fails)) ok, $fails failed"; exit "$fails"
