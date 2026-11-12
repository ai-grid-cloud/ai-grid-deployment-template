#!/usr/bin/env bash
# Tests for scripts/uninstall-check.sh against a stub oc. Nothing here reaches a cluster.
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
D="$T/deploy"; mkdir -p "$T/bin" "$D/.config/hub" "$D/.config/site-b"
cp -R "$SRC/scripts" "$D/"; touch "$D/.config/hub/kubeconfig" "$D/.config/site-b/kubeconfig"
cat > "$D/clusters.yaml" <<'YAML'
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {name: hub, api: "https://api.hub.example.com:6443"}
sites:
  - {name: site-b, role: combined, location: us-east, api: "https://api.site.example.com:6443"}
YAML
for b in kubectl jq; do ln -s "$(command -v "$b")" "$T/bin/$b"; done
# Stub oc: the cluster is the login's directory; $STUB/NAME.crd means the
# Application kind is served, $STUB/NAME.apps lists its Application objects.
cat > "$T/bin/oc" <<'STUB'
#!/usr/bin/env bash
c=$(basename "$(dirname "$KUBECONFIG")"); w="$STUB/$c"
case "$*" in
  whoami) echo admin ;;
  "api-resources --api-group=argoproj.io -o name") [ -f "$w.crd" ] && echo applications.argoproj.io; true ;;
  "get applications.argoproj.io -A -o name")
    [ -f "$w.crd" ] || { echo 'error: the server doesn'"'"'t have a resource type "applications"' >&2; exit 1; }
    cat "$w.apps" 2>/dev/null; true ;;
  "get ns -o name") echo namespace/default ;;
  "get oauth cluster -o jsonpath="*) echo rhbk ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/oc"
export STUB="$T/world"; mkdir -p "$STUB"
run() { (cd "$D" && PATH="$T/bin:$PATH" scripts/uninstall-check.sh); }

section() { run 2>&1 | awk -v n="== $1" '/^== /{on=($0==n)} on'; } # one cluster's lines

touch "$STUB/hub.crd"   # the hub keeps the CRD, with no Applications; site-b has no CRD at all
t "the kind with no objects is none" 0 "^Argo CD Applications: none$" section hub
t "no kind at all is none too" 0 "^Argo CD Applications: none$" section site-b
printf '%s\n' application.argoproj.io/a application.argoproj.io/b > "$STUB/hub.apps"
t "Applications left are counted" 0 "^Argo CD Applications: 2 left$" section hub
t "the kind itself isn't reported" 0 "^ok$" bash -c '! grep -q "Application kind" <<<"$0" && echo ok' "$(run 2>&1)"

echo "uninstall-check tests: $((total-fails)) ok, $fails failed"; exit "$fails"
