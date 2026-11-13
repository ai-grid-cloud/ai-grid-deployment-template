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
ans() { [ -f "$d/$1" ] || { echo "Error from server (NotFound): $1" >&2; exit 1; }; cat "$d/$1"; }
case "$a" in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io deployment-root "*)
    ans deployment-root >/dev/null || exit 1
    sed "s/@HEAD@/$(git -C "$REPO" rev-parse HEAD)/" "$d/deployment-root" ;;
  *" get applications.argoproj.io "*) ans apps.json ;;
  *" get multiclusterhub "*) ans mch.json ;;
  *" get secret ai-grid-backend-git "*) ans console-secret ;;
  *" get placements."*) echo '{"items":[]}' ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

# A fake for each script install.sh calls. bootstrap-hub.sh creates
# deployment-root, Synced at HEAD; git-push.sh commits, as a push would.
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
root_at_head='{"metadata":{"name":"deployment-root"},"status":{"sync":{"status":"Synced","revision":"@HEAD@"},"health":{"status":"Healthy"}}}'

setup() { # NAME: a deployment repository $D and a stub directory $W, for one case
  D="$T/$1/repo" W="$T/$1/stub"; mkdir -p "$W" "$D/.config"
  cp -R "$SRC/scripts" "$D/"
  for s in login.sh set-library.sh set-inputs.sh check-deployment.sh empty-catalog.sh \
      create-console-secrets.sh install-report.sh; do fake "$s"; done
  fake git-push.sh 'git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m pushed'
  fake bootstrap-hub.sh "printf '%s' '$root_at_head' > \"\$STUB_DIR/deployment-root\""
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
  g -C "$D" init -q && g -C "$D" add clusters.yaml install.env && g -C "$D" commit -qm seed
  echo '{"items":[{"status":{"phase":"Running"}}]}' > "$W/mch.json"
  echo '{"items":[{"metadata":{"name":"acm"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}' > "$W/apps.json"
  : > "$W/calls.log"; : > "$W/argv.log"
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
  [ "$(calls)" = "login.sh --non-interactive;set-inputs.sh https://github.com/acme/catalog.git;git-push.sh install: inputs and library pin root/ tenant-idp/manifests/settings.yaml;empty-catalog.sh --check;bootstrap-hub.sh;create-console-secrets.sh;" ]'

setup rerun
printf '%s' "$root_at_head" > "$W/deployment-root"; echo '{}' > "$W/console-secret"
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

t "no token value in any output" eval '[ -n "$all_out" ] && ! grep -qF "$SENTINEL" <<<"$all_out" &&
  ! grep -rqF "$SENTINEL" "$T"/*/repo/.install "$T"/*/stub/calls.log "$T"/*/stub/argv.log 2>/dev/null'

echo "install tests: $((total-fails)) ok, $fails failed"; exit "$fails"
