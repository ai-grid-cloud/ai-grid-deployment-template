#!/usr/bin/env bash
# Tests for scripts/check-deployment.sh and bootstrap-hub.sh's pin check,
# against fixture deployments made from this repository's root/, apps/ and
# hub/catalog/. Uses LIBRARY if set, else fetches the library at the pin.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
LIB=$(scripts/library.sh); export LIBRARY=$LIB
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SHA=$(git -C "$LIB" rev-parse HEAD)

fixture() { # name -> a deployment dir with every input set
  local d="$T/$1"; mkdir -p "$d"
  cp -R "$SRC/root" "$SRC/apps" "$SRC/hub" "$d/"
  cat > "$d/root/inputs.env" <<ENV
deploymentRepoURL=https://git.example.com/acme/deployment.git
deploymentRevision=main
catalogRepoURL=https://git.example.com/acme/catalog.git
catalogRevision=main
keycloakOverlay=core
hubCertManager=library
ENV
  sed -i.bak -E "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops.git#https://git.example.com/acme/library.git#" "$d/root/applicationset.yaml"
  rm "$d/root/applicationset.yaml.bak"
  for f in "$d"/hub/catalog/*.yaml; do
    sed -i.bak -e 's#REQUIRED-catalogRepoURL#https://git.example.com/acme/catalog.git#g' -e 's#REQUIRED-catalogRevision#main#g' "$f"; rm "$f.bak"
  done
  echo "$d"
}

t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

d=$(fixture good)
t "a complete deployment passes" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"

# The scripts render with oc kustomize, not a separate kustomize: a broken one on PATH changes nothing.
mkdir -p "$T/badk"; printf '#!/bin/sh\necho "stub kustomize must not run" >&2; exit 1\n' > "$T/badk/kustomize"; chmod 755 "$T/badk/kustomize"
t "renders with oc kustomize, not kustomize" 0 "every repository is an input" env PATH="$T/badk:$PATH" bash scripts/check-deployment.sh "$d"

d=$(fixture own-app-token)
printf 'spec:\n  source:\n    repoURL: '"'"'@deploymentRepoURL@'"'"'\n' > "$d/apps/idp.yaml"
t "an own app using @deploymentRepoURL@ passes" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"

d=$(fixture copied-app)
printf 'spec:\n  source:\n    repoURL: https://github.com/someone/example-deployment.git\n' > "$d/apps/idp.yaml"
t "an own app left pointing at the copied repository fails" 1 "someone/example-deployment" bash scripts/check-deployment.sh "$d"

d=$(fixture unset)
sed -i.bak '/^catalogRevision=/d' "$d/root/inputs.env"
t "an input missing from inputs.env fails the render" 1 "catalogRevision|oc kustomize" bash scripts/check-deployment.sh "$d"

d=$(fixture placeholders)
sed -i.bak -e 's#^deploymentRepoURL=.*#deploymentRepoURL=REQUIRED-deploymentRepoURL#' \
  -e 's#^catalogRepoURL=.*#catalogRepoURL=REQUIRED-catalogRepoURL#' "$d/root/inputs.env"
t "placeholder inputs are named" 1 "^unset inputs: catalogRepoURL deploymentRepoURL$" bash scripts/check-deployment.sh "$d"

d=$(fixture file-placeholder)
mkdir -p "$d/my-app"; printf 'data:\n  hostname: REQUIRED-hostname\n' > "$d/my-app/settings.yaml"
t "a placeholder left in a deployment file fails" 1 "^my-app/settings.yaml:2:REQUIRED-hostname$" bash scripts/check-deployment.sh "$d"

d=$(fixture template-tests)
cp -R tests "$d/tests"
t "the template's own tests/ (fixtures with placeholders) are ignored" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"
mkdir -p "$d/sites/x/tests"; printf 'host: REQUIRED-nestedHost\n' > "$d/sites/x/tests/values.yaml"
t "  ... but a tests/ directory elsewhere is still scanned" 1 "sites/x/tests/values.yaml:1:REQUIRED-nestedHost" bash scripts/check-deployment.sh "$d"

d=$(fixture catalog-placeholder)
cp "$SRC/hub/catalog/catalog-03-appprojects.yaml" "$d/hub/catalog/"
t "a placeholder left in a deployment file fails" 1 "^hub/catalog/catalog-03-appprojects.yaml:[0-9]+:REQUIRED-catalogRepoURL$" \
  bash scripts/check-deployment.sh "$d"

d=$(fixture catalog-mismatch)
sed -i.bak 's#^catalogRepoURL=.*#catalogRepoURL=https://git.example.com/acme/other-catalog.git#' "$d/root/inputs.env"
t "hub/catalog naming another catalog than inputs.env fails" 1 "hub/catalog names .*acme/catalog.git.*other-catalog.*set-inputs.sh" \
  bash scripts/check-deployment.sh "$d"

d=$(fixture bad-choices)
sed -i.bak 's#^keycloakOverlay=.*#keycloakOverlay=examples#' "$d/root/inputs.env"
t "an unknown keycloakOverlay fails the check" 1 "keycloakOverlay is examples: core or default" bash scripts/check-deployment.sh "$d"
d=$(fixture bad-cm)
sed -i.bak 's#^hubCertManager=.*#hubCertManager=platfrom#' "$d/root/inputs.env"
t "an unknown hubCertManager fails the check" 1 "hubCertManager is platfrom: library, platform or site" bash scripts/check-deployment.sh "$d"

d=$(fixture old-site-files)
mkdir -p "$d/values/clusters/site-a" "$d/sites/site-a/maas-tls"; : > "$d/values/clusters/site-a/rhoai.yaml"; : > "$d/apps/site-a-maas-tls.yaml"
t "per-site files from an earlier template fail the check, named" 1 "per-site files the library's main branch doesn't read: values/clusters/ apps/site-a-maas-tls.yaml sites/site-a/maas-tls" \
  bash scripts/check-deployment.sh "$d"

d=$(fixture fetched-library)
mkdir -p "$d/.library/apps"; printf 'x: REQUIRED-libraryRepoURL\n' > "$d/.library/apps/inputs.yaml"
t "placeholders in the fetched .library/ are ignored" 0 "every repository is an input" bash scripts/check-deployment.sh "$d"

t "no root/ is a usage error" 2 "Usage" bash scripts/check-deployment.sh "$T/nothing"

d=$(fixture pin)
sed -i.bak "s/$SHA/0123456789abcdef0123456789abcdef01234567/g" "$d/root/applicationset.yaml"
t "bootstrap-hub refuses a library checkout off the pin" 1 "isn't at your pin 0123456789abcdef" \
  env PATH="$T/badk:$PATH" bash -c 'f=$(mktemp); echo {} > "$f"; RHOAI_QUAY_AUTH_FILE=$f KUBECONFIG=$f bash scripts/bootstrap-hub.sh --deployment "$0"' "$d"

# bootstrap-hub checks the auth file before it writes to the hub: a stub oc
# logs every call, and a refused auth file must leave no oc apply.
d=$(fixture auth)
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\n' > "$d/clusters.yaml"
mkdir -p "$d/.config/hub" "$T/ocbin"; : > "$d/.config/hub/kubeconfig"
cat > "$T/ocbin/oc" <<STUB
#!/bin/bash
echo "oc \$*" >> "$T/oc.log"
case "\$1" in kustomize|label) exec "$(command -v oc)" "\$@" ;; whoami) echo https://api.hub.example.com:6443 ;; esac
case "\$*" in *"get argocd openshift-gitops"*) echo Available ;; esac
case "\$*" in *"get operatorgroups.operators.coreos.com -n cert-manager-operator"*) [ ! -f "$T/platform-cm" ] || echo cert-manager-operator-og ;; esac
STUB
chmod +x "$T/ocbin/oc"
printf '{"auths":{"quay.io":{"auth":"dTpw"}}}' > "$T/generic.json"
: > "$T/oc.log"
t "bootstrap-hub refuses a general login before any write" 1 "no quay.io/rhoai login in .*generic.json.*ALLOW_GENERIC_LOGIN=1" \
  env PATH="$T/ocbin:$PATH" QUAY_AUTH_FILE="$T/generic.json" bash scripts/bootstrap-hub.sh --deployment "$d"
t "  ... and made no oc apply" 0 "^ok$" bash -c '! grep -q " apply" "$0" && echo ok' "$T/oc.log"
printf 'not json' > "$T/bad.json"
t "bootstrap-hub refuses an unreadable auth file" 1 "can't read .*bad.json" \
  env PATH="$T/ocbin:$PATH" QUAY_AUTH_FILE="$T/bad.json" bash scripts/bootstrap-hub.sh --deployment "$d"

# Without a registry.stage.redhat.io login no model runtime pulls on a site
# (the library mirrors rhaii* there with no fallback): stops before any write.
printf '{"auths":{"quay.io/rhoai":{"auth":"dTpw"}}}' > "$T/nostage.json"; : > "$T/oc.log"
t "bootstrap-hub refuses an auth file with no stage login" 1 "no registry.stage.redhat.io login in .*nostage.json.*L20" \
  env PATH="$T/ocbin:$PATH" QUAY_AUTH_FILE="$T/nostage.json" bash scripts/bootstrap-hub.sh --deployment "$d"
t "  ... and made no oc apply" 0 "^ok$" bash -c '! grep -q " apply" "$0" && echo ok' "$T/oc.log"

# On a fresh hub the controller needs the library's memory before the root fans
# out (gitops-config can't apply it until ACM exists): the patch comes first.
printf '{"auths":{"quay.io/rhoai":{"auth":"dTpw"},"registry.stage.redhat.io":{"auth":"czpw"}}}' > "$T/rhoai.json"; : > "$T/oc.log"
env PATH="$T/ocbin:$PATH" QUAY_AUTH_FILE="$T/rhoai.json" bash scripts/bootstrap-hub.sh --deployment "$d" >/dev/null 2>&1 || true
t "bootstrap-hub sets the controller's memory from the library" 0 '"limits":\{"memory":"8Gi"\}' grep "patch argocd openshift-gitops" "$T/oc.log"
t "  ... before it applies the root" 0 "^ok$" bash -c 'p=$(grep -n "patch argocd" "$0" | head -1 | cut -d: -f1); r=$(grep -n "apply -f -" "$0" | head -1 | cut -d: -f1); [ -n "$p" ] && [ -n "$r" ] && [ "$p" -lt "$r" ] && echo ok' "$T/oc.log"

# hubCertManager=library (the fixture's) on a hub that runs the platform's
# cert-manager: stops before any write.
touch "$T/platform-cm"; : > "$T/oc.log"
t "bootstrap-hub stops on the platform's cert-manager with hubCertManager=library" 1 "set hubCertManager=platform in root/inputs.env" \
  env PATH="$T/ocbin:$PATH" QUAY_AUTH_FILE="$T/rhoai.json" bash scripts/bootstrap-hub.sh --deployment "$d"
t "  ... and made no oc apply" 0 "^ok$" bash -c '! grep -q " apply" "$0" && echo ok' "$T/oc.log"
rm "$T/platform-cm"

echo "deployment-scripts tests: $((total-fails)) ok, $fails failed"; exit "$fails"
