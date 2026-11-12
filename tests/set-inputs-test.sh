#!/usr/bin/env bash
# Tests for scripts/set-inputs.sh against a copy of this repository's root/ and
# tenant-idp/, a stub oc for the apps domains, and the library at the pin (the
# copy's root takes it from the local checkout, so nothing is fetched).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
LIB=$(scripts/library.sh); export LIBRARY=$LIB
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
REAL_OC=$(command -v oc)

t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
check() { # name condition...
  total=$((total+1)); if "${@:2}"; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1"; fi
}

# The stub oc: whoami works, the apps domain is apps.<cluster>.example.com from
# the kubeconfig's directory, and kustomize goes to the real oc.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<EOF
#!/bin/bash
case "\$1" in
  whoami) echo stub ;;
  kustomize) exec "$REAL_OC" "\$@" ;;
  get) n=\$(basename "\$(dirname "\$KUBECONFIG")"); printf 'apps.%s.example.com' "\$n" ;;
  *) echo "stub oc: unexpected: \$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/oc"

repo() { # name origin -> a deployment copy with clusters.yaml and logins
  local d="$T/$1"; mkdir -p "$d"
  cp -R "$SRC/scripts" "$SRC/root" "$SRC/tenant-idp" "$d/"
  # Take the library from the local checkout instead of github.com.
  local rel; rel=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$LIB/bootstrap/hub" "$d/root")
  sed -i.bak -E "s#^  - https://github.com/[^ ]+//bootstrap/hub\?ref=[0-9a-f]+#  - $rel#" "$d/root/kustomization.yaml"
  rm "$d/root/kustomization.yaml.bak"
  cat > "$d/clusters.yaml" <<'YAML'
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub: {name: hub, api: 'https://api.hub.example.com:6443'}
sites:
  - {name: site-i, role: inference, location: us-west, api: 'https://api.site-i.example.com:6443'}
  - {name: site-c, role: combined, location: us-east, api: 'https://api.site-c.example.com:6443'}
YAML
  for n in hub site-i site-c; do mkdir -p "$d/.config/$n"; : > "$d/.config/$n/kubeconfig"; done
  git -C "$d" init -q && git -C "$d" remote add origin "$2"
  echo "$d"
}

d=$(repo ssh git@github.com:acme/deploy.git)
grep 'op: test' "$d/root/kustomization.yaml" > "$T/tests-before"
t "sets the values and checks" 0 "every repository is an input" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" git@github.com:acme/catalog.git
k="$d/root/kustomization.yaml"
check "deploymentRepoURL from origin, as https" grep -q '&deploymentRepoURL https://github.com/acme/deploy.git$' "$k"
check "catalogRepoURL from the argument, as https" grep -q 'catalogRepoURL: https://github.com/acme/catalog.git$' "$k"
check "idpIssuerURL from the hub" grep -q 'idpIssuerURL: https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants$' "$k"
check "self.yaml repoURL" grep -q 'repoURL: https://github.com/acme/deploy.git$' "$d/root/self.yaml"
check "portalRedirectURI from the first combined or ingress site" \
  grep -q 'portalRedirectURI: https://maas.apps.site-c.example.com/\*$' "$d/tenant-idp/manifests/settings.yaml"
check "op: test lines untouched" diff -q "$T/tests-before" <(grep 'op: test' "$k")
check "op: test placeholders kept" grep -q 'value: REQUIRED-libraryRepoURL' "$k"
t "a second run keeps the values" 0 "kept +root/kustomization.yaml: catalogRepoURL is already set" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/other.git
check "a second run changes nothing" grep -q 'catalogRepoURL: https://github.com/acme/catalog.git$' "$k"

d=$(repo https https://user@github.com/acme/deploy)
t "https origin: credentials dropped, .git added" 0 "deploymentRepoURL = https://github.com/acme/deploy.git$" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog
t "no argument is a usage error" 2 "usage" "$d/scripts/set-inputs.sh"

echo "set-inputs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
