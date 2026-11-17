#!/usr/bin/env bash
# Tests for scripts/site-files.sh: the files it writes from site-template/ for
# a site, by the site's issuer setting and its cert-manager. A stub oc answers
# from files in $STUB_DIR, by the cluster its KUBECONFIG names.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
t() { # name condition...
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

# The stub oc: whoami works; NAME.err is an error, a missing NAME is NotFound.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR c=$(basename "$(dirname "$KUBECONFIG")") a=" $* "
ans() { [ ! -f "$d/$c-$1.err" ] || { cat "$d/$c-$1.err" >&2; exit 1; }
  [ -f "$d/$c-$1" ] || { echo "Error from server (NotFound): $1" >&2; exit 1; }; cat "$d/$c-$1"; }
case "$a" in
  *" whoami "*) echo admin ;;
  *" get ingresses.config.openshift.io cluster "*) ans domain ;;
  *" get operatorgroups."*) [ ! -f "$d/$c-ogs.err" ] || { cat "$d/$c-ogs.err" >&2; exit 1; }
    [ -f "$d/$c-ogs" ] && cat "$d/$c-ogs" || true ;;
  *" get clusterissuers."*) set -- $*; ans "issuer-$3" ;;
  *" get managedclusters."*) [ ! -f "$d/$c-warn" ] || echo "Warning: a deprecation" >&2; ans enabled ;;
  *" get namespace/cert-manager-operator "*) ans protected ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

setup() { # NAME [SITE_YAML]: a deployment repository $D and stub directory $W
  D="$T/$1/repo" W="$T/$1/stub"; mkdir -p "$W" "$D/.config/hub" "$D/.config/site-a"
  cp -R "$SRC/scripts" "$SRC/site-template" "$D/"
  touch "$D/.config/hub/kubeconfig" "$D/.config/site-a/kubeconfig"
  cat > "$D/clusters.yaml" <<YAML
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {api: "https://api.hub.example.com:6443"}
sites:
- ${2:-"{name: site-a, api: \"https://api.site-a.example.com:6443\"}"}
YAML
  echo apps.site-a.example.com > "$W/site-a-domain"
}
run() { out=$(cd "$D" && env PATH="$T/bin:$PATH" STUB_DIR="$W" scripts/site-files.sh site-a 2>&1) && rc=0 || rc=$?; }
with_issuer='{name: site-a, api: "https://api.site-a.example.com:6443", maasCertificate: {issuer: le-dns}}'
v() { cat "$D/values/clusters/site-a/rhoai.yaml"; }
yaml_ok() { for f in "$@"; do KUBECONFIG=/dev/null kubectl create --dry-run=client -o name -f "$f" >/dev/null 2>&1 ||
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f" || return 1; done; }

echo "== nothing to do: no issuer, no platform cert-manager"
setup none
run
t "writes nothing" eval '[ "$rc" = 0 ] && [ ! -e "$D/values" ] && [ ! -e "$D/sites" ] && [ ! -e "$D/apps" ]'

echo "== an issuer: the certificate, its app and the listeners, with the hostname"
setup issuer "$with_issuer"
touch "$W/site-a-issuer-le-dns"
run
t "exits 0 and says what it wrote" eval '[ "$rc" = 0 ] && grep -q "wrote    values/clusters/site-a/rhoai.yaml" <<<"$out" &&
  grep -q "wrote    apps/site-a-maas-tls.yaml" <<<"$out" && grep -q "wrote    sites/site-a/maas-tls/certificate.yaml" <<<"$out"'
t "the certificate names the hostname and issuer" eval 'grep -q "^    - maas.apps.site-a.example.com\$" "$D/sites/site-a/maas-tls/certificate.yaml" &&
  grep -q "^    name: le-dns\$" "$D/sites/site-a/maas-tls/certificate.yaml"'
t "the app delivers sites/site-a/maas-tls to site-a" eval 'grep -q "path: sites/site-a/maas-tls" "$D/apps/site-a-maas-tls.yaml" &&
  grep -q "9092/site-a\$" "$D/apps/site-a-maas-tls.yaml" && grep -q "name: site-a-maas-tls" "$D/apps/site-a-maas-tls.yaml"'
t "both listeners carry the hostname, https the certificate's Secret" eval '[ "$(grep -c "hostname: maas.apps.site-a.example.com" "$D/values/clusters/site-a/rhoai.yaml")" = 2 ] &&
  grep -q "name: maas-gateway-public-tls" "$D/values/clusters/site-a/rhoai.yaml"'
t "no cert-manager override, no placeholder left" eval '! grep -q "certManager" "$D/values/clusters/site-a/rhoai.yaml" &&
  ! grep -rqE "SITE|APPS_DOMAIN|DNS01_ISSUER" "$D/values" "$D/sites" "$D/apps"'
t "every file is valid YAML and starts with the marker" eval 'for f in "$D/values/clusters/site-a/rhoai.yaml" "$D"/sites/site-a/maas-tls/*.yaml "$D/apps/site-a-maas-tls.yaml"; do
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" && head -n 1 "$f" | grep -q "^# Written by scripts/site-files.sh" || exit 1; done'
run
t "a second run changes nothing" eval '[ "$rc" = 0 ] && ! grep -q "^wrote" <<<"$out" && [ "$(grep -c "^unchanged" <<<"$out")" = 4 ]'

echo "== an issuer the site doesn't have"
setup no-issuer "$with_issuer"
run
t "stops and names it, writes nothing" eval '[ "$rc" = 1 ] && grep -q "site site-a has no ClusterIssuer le-dns" <<<"$out" && [ ! -e "$D/values" ]'

echo "== the platform's cert-manager on a site not yet in the grid"
setup platform
echo "cert-manager-operator-og" > "$W/site-a-ogs"
run
t "turns the chart's cert-manager off, nothing else" eval '[ "$rc" = 0 ] && grep -q "^    enabled: false\$" <(v) && ! grep -q "components:" <(v) &&
  [ ! -e "$D/sites" ] && [ ! -e "$D/apps" ] && python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d == {\"dependencies\": {\"certManager\": {\"enabled\": False}}}" "$D/values/clusters/site-a/rhoai.yaml"'
setup chart-og
echo "openshift-cert-manager-operator" > "$W/site-a-ogs"
run
t "the chart's own OperatorGroup alone isn't the platform's" eval '[ "$rc" = 0 ] && [ ! -e "$D/values" ]'

echo "== the platform's cert-manager and an issuer"
setup both "$with_issuer"
touch "$W/site-a-issuer-le-dns"; echo "openshift-cert-manager-operator cert-manager-operator-og" > "$W/site-a-ogs"
run
t "one values file with both" eval '[ "$rc" = 0 ] && python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d[\"dependencies\"][\"certManager\"][\"enabled\"] is False and len(d[\"components\"][\"aigateway\"][\"modelsAsAService\"][\"gateway\"][\"spec\"][\"listeners\"]) == 2" "$D/values/clusters/site-a/rhoai.yaml"'

echo "== a site already in the grid"
setup joined
echo "cert-manager-operator-og" > "$W/site-a-ogs"; echo true > "$W/hub-enabled"
run
t "refuses the cert-manager change and says how to protect the operator" eval '[ "$rc" = 1 ] && grep -q "Prune=false" <<<"$out" &&
  grep -q "page 6" <<<"$out" && [ ! -e "$D/values" ]'
printf 'Prune=false\nPrune=false\n' > "$W/site-a-protected"
run
t "goes ahead once both carry Prune=false" eval '[ "$rc" = 0 ] && grep -q "^    enabled: false\$" <(v)'
run
t "a later run is unchanged, not refused" eval '[ "$rc" = 0 ] && grep -q "^unchanged" <<<"$out"'
setup half
echo "cert-manager-operator-og" > "$W/site-a-ogs"; echo true > "$W/hub-enabled"; printf 'Prune=false\n' > "$W/site-a-protected"
run
t "only one of the two protected: still refuses" eval '[ "$rc" = 1 ] && grep -q "Prune=false" <<<"$out" && [ ! -e "$D/values" ]'
setup warn
echo "cert-manager-operator-og" > "$W/site-a-ogs"; echo true > "$W/hub-enabled"; touch "$W/hub-warn"
run
t "an oc warning on the hub read doesn't skip the guard" eval '[ "$rc" = 1 ] && grep -q "is in the grid" <<<"$out" && [ ! -e "$D/values" ]'
setup hub-error
echo "cert-manager-operator-og" > "$W/site-a-ogs"; echo "error: connection refused" > "$W/hub-enabled.err"
run
t "a hub it can't read stops it" eval '[ "$rc" = 1 ] && grep -q "can.t read ManagedCluster site-a" <<<"$out" && [ ! -e "$D/values" ]'

echo "== reads that fail"
setup og-error
echo "error: forbidden" > "$W/site-a-ogs.err"
run
t "an OperatorGroup read that fails stops it" eval '[ "$rc" = 1 ] && grep -q "can.t read site site-a.s OperatorGroups" <<<"$out" && [ ! -e "$D/values" ]'
setup domain-error
rm "$W/site-a-domain"
run
t "no apps domain stops it" eval '[ "$rc" = 1 ] && grep -q "can.t read site site-a.s apps domain" <<<"$out"'

setup domain-odd
echo 'x/g;s/a/b' > "$W/site-a-domain"
run
t "an apps domain that isn't a DNS name stops it" eval '[ "$rc" = 1 ] && grep -q "apps domain isn.t a DNS name" <<<"$out" && [ ! -e "$D/values" ]'

echo "== the platform's cert-manager gone later"
setup gone
echo "cert-manager-operator-og" > "$W/site-a-ogs"
run
rm "$W/site-a-ogs"
run
t "removes the values file it wrote" eval '[ "$rc" = 0 ] && grep -q "^removed  values/clusters/site-a/rhoai.yaml" <<<"$out" && [ ! -e "$D/values" ]'

echo "== your own file"
setup yours "$with_issuer"
touch "$W/site-a-issuer-le-dns"
mkdir -p "$D/values/clusters/site-a"; printf 'dependencies:\n  certManager:\n    enabled: auto\n' > "$D/values/clusters/site-a/rhoai.yaml"
run
t "kept, with what it would have written" eval '[ "$rc" = 0 ] && grep -q "kept     values/clusters/site-a/rhoai.yaml (yours" <<<"$out" &&
  grep -q "hostname: maas.apps.site-a.example.com" <<<"$out" && grep -q "enabled: auto" <(v) && [ -e "$D/apps/site-a-maas-tls.yaml" ]'

echo "== the issuer removed later"
setup removed "$with_issuer"
touch "$W/site-a-issuer-le-dns"
run
sed -i.bak 's/, maasCertificate: {issuer: le-dns}//' "$D/clusters.yaml"
run
t "removes the files it wrote" eval '[ "$rc" = 0 ] && [ ! -e "$D/values" ] && [ ! -e "$D/sites" ] && [ ! -e "$D/apps/site-a-maas-tls.yaml" ] &&
  [ "$(grep -c "^removed" <<<"$out")" = 4 ]'

echo "== clusters.yaml checks"
setup bad-map '{name: site-a, api: "https://api.site-a.example.com:6443", maasCertificate: le-dns}'
run
t "maasCertificate must be a map" eval '[ "$rc" = 1 ] && grep -q "sites\[site-a\].maasCertificate must be a map" <<<"$out"'
setup bad-key '{name: site-a, api: "https://api.site-a.example.com:6443", maasCertificate: {isuer: le-dns}}'
run
t "an unknown key under it is named" eval '[ "$rc" = 1 ] && grep -q "sites\[site-a\].maasCertificate.isuer" <<<"$out"'
setup bad-name '{name: site-a, api: "https://api.site-a.example.com:6443", maasCertificate: {issuer: "Not An Issuer"}}'
run
t "the issuer must be a name" eval '[ "$rc" = 1 ] && grep -q "maasCertificate.issuer must name a ClusterIssuer" <<<"$out"'

echo "== the template itself"
t "site-template's values file parses with the cert-manager lines uncommented" eval 'sed -E "s/^# (dependencies:|  certManager:|    enabled: false)\$/\\1/" "$SRC/site-template/values/clusters/SITE/rhoai.yaml" |
  python3 -c "import sys, yaml; d = yaml.safe_load(sys.stdin); assert d[\"dependencies\"][\"certManager\"][\"enabled\"] is False and \"components\" in d"'

echo "site-files: $((total - fails))/$total passed"
[ "$fails" = 0 ]
