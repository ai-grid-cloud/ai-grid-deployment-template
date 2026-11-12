#!/usr/bin/env bash
# Tests for scripts/create-console-secrets.sh's wait, with a stub oc and a stub
# library whose create-secrets.sh only reports that it ran.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

t() { # name want_rc expect_grep [reject_grep]
  local name=$1 want=$2 expect=$3 reject=${4:-} rc out
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" LIBRARY="$T/lib" CONSOLE_WAIT_SECONDS=2 CONSOLE_WAIT_INTERVAL=1 \
    "$D/scripts/create-console-secrets.sh" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; }; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/lib/apps/console" "$T/bin"
echo 'echo "library create-secrets ran"' > "$T/lib/apps/console/create-secrets.sh"
git -c init.defaultBranch=main -C "$T/lib" init -q && git -C "$T/lib" add -A && git -c core.hooksPath=/dev/null -C "$T/lib" commit -qm lib
D="$T/repo"; mkdir -p "$D/root" "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf '  libraryRevision: %s\n' "$(git -C "$T/lib" rev-parse HEAD)" > "$D/root/kustomization.yaml"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"

# The stub oc answers from files in $STUB_DIR; a missing file is NotFound.
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; a=" $* "
ans() { [ -f "$d/$1" ] || { echo NotFound >&2; exit 1; }; cat "$d/$1"; }
case "$a" in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io tenant-idp "*) ans tenant-idp ;;
  *" get route "*) ans route ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

W="$T/ready"; mkdir -p "$W"; printf 'Synced Healthy' > "$W/tenant-idp"; printf 'console.apps.hub.example.com' > "$W/route"
t "ready: runs the library script" 0 "library create-secrets ran" "Waiting"
t "ready: names the console" 0 "console is at https://console.apps.hub.example.com"

W="$T/not-ready"; mkdir -p "$W"; printf 'Synced Progressing' > "$W/tenant-idp"
t "not ready: progress line" 1 "Waiting for the tenant Keycloak and the console: tenant-idp: Synced Progressing; console Route: not created yet"
t "not ready: times out pointing to make status" 1 "error: not ready after .*Run make status" "library create-secrets ran"

echo "console-secrets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
