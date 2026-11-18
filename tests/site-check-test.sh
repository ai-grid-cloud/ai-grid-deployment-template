#!/usr/bin/env bash
# Tests for scripts/site-check.sh's own checks, with a stub oc and a stub
# check-prerequisites.sh (no cluster).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
t() { # name want_rc expect_grep
  local name=$1 want=$2 expect=$3 rc out; total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" "$D/scripts/site-check.sh" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
case " $* " in
  *" whoami "*) echo admin ;;
  *" get ingresses.config.openshift.io "*) printf 'localhost' ;;
  *" get nodes -o json "*) cat "$STUB_DIR/nodes.json" ;;
  *" get operatorgroups.operators.coreos.com -n cert-manager-operator "*)
    [ ! -f "$STUB_DIR/og-error" ] || { echo "error: Forbidden" >&2; exit 1; }
    cat "$STUB_DIR/ogs" 2>/dev/null || true ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"
D="$T/repo"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"
printf '#!/bin/bash\nexit 0\n' > "$D/scripts/check-prerequisites.sh"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
for n in hub site-b; do mkdir -p "$D/.config/$n"; : > "$D/.config/$n/kubeconfig"; done
w() { printf '{"metadata":{"name":"%s","labels":{"node-role.kubernetes.io/%s":""}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' "$1" "$2"; }
echo "{\"items\":[$(w w1 worker),$(w w2 worker)]}" > "$T/nodes.json"
# The apps domain is localhost, so router-default.localhost resolves where the
# resolver maps *.localhost; the cert-manager lines are what's tested.
t "no OperatorGroup: OK" 0 "^OK +cert-manager OperatorGroup"
printf 'openshift-cert-manager-operator' > "$T/ogs"
t "only the chart's own (a site that already joined): OK" 0 "^OK +cert-manager OperatorGroup"
printf 'cert-manager-operator-og' > "$T/ogs"
t "the platform's cert-manager: FOUND, names the limit, exit 1" 1 "^FOUND +cert-manager OperatorGroup +cert-manager-operator-og: .*TooManyOperatorGroups.*upstream-main-limits.md"
touch "$T/og-error"
t "can't read: MISSING, exit 1" 1 "^MISSING +cert-manager OperatorGroup +can't read OperatorGroups in cert-manager-operator: error: Forbidden"
rm "$T/og-error"; : > "$T/ogs"
t "two workers to label: OK, says which" 0 "^OK +Submariner gateway nodes +would label w1, w2 submariner.io/gateway=true"
echo "{\"items\":[$(w m1 master),$(w m2 master)]}" > "$T/nodes.json"
t "no worker to label: MISSING, names the oc label command, exit 1" 1 "^MISSING +Submariner gateway nodes +site-b needs two .*oc label node m1 m2 submariner.io/gateway=true$"
echo "site-check tests: $((total-fails)) ok, $fails failed"; exit "$fails"
