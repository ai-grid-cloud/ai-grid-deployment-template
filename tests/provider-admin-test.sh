#!/usr/bin/env bash
# Tests for scripts/provider-admin.sh with a stub oc and a stub curl (no
# cluster, no console). The stub oc logs its arguments to $STUB_DIR/argv.log and
# answers from files; the stub curl logs its arguments to $STUB_DIR/curl.log,
# copies the header files it's given to $STUB_DIR/headers, and answers with the
# HTTP code in $STUB_DIR/code (200 when there's none).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

run() { # runs provider-admin.sh in $D with the stubs reading $W; sets rc and out
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/provider-admin.sh" 2>&1) && rc=0 || rc=$?
}
t() { # name want_rc expect_grep [check...]: each check is a command that must succeed
  local name=$1 want=$2 expect=$3; shift 3; local check ok=1
  total=$((total+1))
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && ! grep -q SENTINEL <<<"$out"; then
    for check in "$@"; do eval "$check" || { ok=0; echo "      check failed: $check"; }; done
  else ok=0; fi
  if [ "$ok" = 1 ]; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; a=" $* "
case "$a" in
  *" whoami "*) echo admin ;;
  *" get clusterrole ai-grid-provider-admin "*)
    [ -f "$d/no-clusterrole" ] && { echo 'Error from server (NotFound): clusterroles "ai-grid-provider-admin" not found' >&2; exit 1; }
    echo clusterrole.rbac.authorization.k8s.io/ai-grid-provider-admin ;;
  *" apply "*) cat >> "$d/applied.yaml"; echo "applied" ;;
  *" create token provider-admin "*) echo SENTINEL ;;
  *" get route "*) printf 'console.apps.hub.example.com' ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.log"
out="" prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  [ "$prev" = -H ] && case "$a" in @*) cat "${a#@}" >> "$STUB_DIR/headers" ;; esac
  prev=$a
done
[ -n "$out" ] && echo '{"clusters":[]}' > "$out"
cat "$STUB_DIR/code" 2>/dev/null || printf 200
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

D="$T/repo"; mkdir -p "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"
TOK="$D/.config/provider-admin-token"
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

W="$T/first"; mkdir -p "$W"; run
t "creates SA, binding and token file" 0 "console accepted the provider-admin token" \
  'grep -qx SENTINEL "$TOK"' '[ "$(mode "$TOK")" = 600 ]' \
  'grep -q "kind: Namespace" "$W/applied.yaml" && grep -q "name: ai-grid-test$" "$W/applied.yaml"' \
  'grep -q "kind: ServiceAccount" "$W/applied.yaml" && grep -q "name: provider-admin$" "$W/applied.yaml"' \
  'grep -q "name: ai-grid-test-provider-admin$" "$W/applied.yaml" && grep -q "name: ai-grid-provider-admin$" "$W/applied.yaml"' \
  'grep -q "create token provider-admin -n ai-grid-test --duration=168h" "$W/argv.log"' \
  'grep -q "Authorization: Bearer SENTINEL" "$W/headers"' \
  '! grep -q SENTINEL "$W/curl.log"' '! grep -qE -- " (-k|--insecure) " "$W/curl.log"' \
  'grep -q "https://console.apps.hub.example.com/ai_grid.v1.Clusters/List" "$W/curl.log"' \
  'grep -q "Connect-Protocol-Version: 1" "$W/curl.log"'

W="$T/norole"; mkdir -p "$W"; touch "$W/no-clusterrole"; rm -f "$TOK"; run
t "no ClusterRole: stops" 1 "ClusterRole ai-grid-provider-admin" \
  '[ ! -f "$TOK" ]' '! grep -q "create token" "$W/argv.log"' '[ ! -f "$W/curl.log" ]'

W="$T/refused"; mkdir -p "$W"; printf 401 > "$W/code"; run
t "call refused: stops with the code" 1 "HTTP 401.*didn't accept the ServiceAccount token"

W="$T/rerun"; mkdir -p "$W"; run; run
t "rerun: apply is idempotent" 0 "console accepted" \
  '[ "$(grep -c "^apply " "$W/argv.log")" -ge 2 ]' \
  '! grep -qE "create (namespace|ns|serviceaccount|sa|clusterrolebinding)( |$)" "$W/argv.log"' \
  'grep -qx SENTINEL "$TOK"'

echo "provider-admin tests: $((total-fails)) ok, $fails failed"; exit "$fails"
