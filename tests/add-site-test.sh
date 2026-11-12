#!/usr/bin/env bash
# Tests for scripts/add-site.sh with a stub oc, the real site-template/, and a
# stub check-deployment.sh (the root's inputs aren't the point here).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_grep [args...]: runs add-site.sh in $D with the stub oc reading $W
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" "$D/scripts/add-site.sh" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
check() { total=$((total+1)); if "${@:2}"; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1"; fi; }

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; a=" $* "
case "$a" in
  *" whoami "*) echo admin ;;
  *" get ingresses.config.openshift.io "*) printf 'apps.site-b.example.com' ;;
  *" get clusterissuers.cert-manager.io "*) cat "$d/issuers.json" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"
issuer() { printf '{"metadata":{"name":"%s"},"spec":{"acme":{"solvers":[{"%s":{}}]}}}' "$1" "$2"; }

repo() { # name sites-yaml -> a deployment copy
  local d="$T/$1"; mkdir -p "$d"; cp -R "$SRC/scripts" "$SRC/site-template" "$d/"
  printf '#!/bin/bash\necho "check-deployment ran"\n' > "$d/scripts/check-deployment.sh"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n%s\n' "$2" > "$d/clusters.yaml"
  for n in hub site-b site-i; do mkdir -p "$d/.config/$n"; : > "$d/.config/$n/kubeconfig"; done
  echo "$d"
}
B='  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}'
I='  - {name: site-i, role: inference, location: us-west, api: "https://api.site-i.example.com:6443"}'

W="$T/one"; mkdir -p "$W"; echo "{\"items\":[$(issuer le-dns dns01),$(issuer le-http http01)]}" > "$W/issuers.json"
D=$(repo one "$B")
t "one DNS-01 issuer: writes the files" 0 "wrote +sites/site-b/maas-tls/certificate.yaml"
check "certificate names the issuer and host" grep -q 'name: le-dns' "$D/sites/site-b/maas-tls/certificate.yaml"
check "  ... and the MaaS hostname" grep -q -- '- maas.apps.site-b.example.com$' "$D/sites/site-b/maas-tls/certificate.yaml"
check "Application for the site" grep -q 'path: sites/site-b/maas-tls' "$D/apps/site-b-maas-tls.yaml"
check "values for the site" test -f "$D/values/clusters/site-b/rhoai.yaml"
check "no placeholder left" bash -c '! grep -rqE "SITE|APPS_DOMAIN|DNS01_ISSUER" "$0/apps" "$0/sites" "$0/values"' "$D"
t "runs the check and prints the git commands" 0 "git add apps/site-b-maas-tls.yaml sites/site-b/maas-tls/certificate.yaml values/clusters/site-b/rhoai.yaml"
t "a second run keeps the files" 0 "kept +apps/site-b-maas-tls.yaml \(exists\)"
echo "# my edit" >> "$D/values/clusters/site-b/rhoai.yaml"
t "a changed file is kept as it is" 0 "kept +values/clusters/site-b/rhoai.yaml"
check "  ... with your edit" grep -q "# my edit" "$D/values/clusters/site-b/rhoai.yaml"
rm "$D/sites/site-b/maas-tls/certificate.yaml"
t "a missing file is written again" 0 "wrote +sites/site-b/maas-tls/certificate.yaml"

W="$T/two"; mkdir -p "$W"; echo "{\"items\":[$(issuer le-dns dns01),$(issuer le-dns-staging dns01)]}" > "$W/issuers.json"
D=$(repo two "$B")
t "two DNS-01 issuers: lists them" 1 "^  le-dns-staging$"
t "  ... and says how to choose one" 1 "make site-add SITE=site-b ISSUER=ISSUER"
t "an issuer named" 0 "certificate from ClusterIssuer le-dns-staging" site-b le-dns-staging
rm -rf "$D/apps" "$D/sites" "$D/values"
t "an issuer that isn't DNS-01" 1 "le-http isn't a DNS-01 ClusterIssuer" site-b le-http

W="$T/none"; mkdir -p "$W"; echo "{\"items\":[$(issuer le-http http01)]}" > "$W/issuers.json"
D=$(repo none "$B")
t "no DNS-01 issuer" 1 "has no DNS-01 ClusterIssuer"

# All files present: no issuer needed (this site has no DNS-01 one), and nothing to commit
# once they're committed.
D=$(repo all-there "$B")
for f in apps/site-b-maas-tls.yaml sites/site-b/maas-tls/certificate.yaml values/clusters/site-b/rhoai.yaml; do
  mkdir -p "$D/$(dirname "$f")"; echo "x: 1" > "$D/$f"; done
t "all files there: no issuer needed" 0 "kept +values/clusters/site-b/rhoai.yaml \(exists\)"
git -c init.defaultBranch=main -C "$D" init -q && git -C "$D" add -A &&
  git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com -C "$D" commit -qm all
t "  ... and nothing to commit" 0 "^Nothing to commit: the site's files are already committed.$"
D=$(repo inference "$I")
t "an inference site needs no files" 0 "site-i is an inference site: it needs no MaaS files"

echo "add-site tests: $((total-fails)) ok, $fails failed"; exit "$fails"
