#!/usr/bin/env bash
# Tests for scripts/set-inputs.sh and root/inputs.env against a copy of this repository's root/ and
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
hub: {api: 'https://api.hub.example.com:6443'}
sites:
  - {name: site-i, api: 'https://api.site-i.example.com:6443'}
  - {name: site-c, api: 'https://api.site-c.example.com:6443'}
YAML
  for n in hub site-i site-c; do mkdir -p "$d/.config/$n"; : > "$d/.config/$n/kubeconfig"; done
  git -C "$d" init -q && git -C "$d" remote add origin "$2"
  echo "$d"
}

d=$(repo ssh git@github.com:acme/deploy.git)
cp "$d/root/kustomization.yaml" "$T/kustomization-before"; cp "$d/root/self.yaml" "$T/self-before"
t "without inputs.env the check names make inputs" 1 "root/inputs.env is missing: run make inputs CATALOG=CATALOG_REPO_URL" \
  env PATH="$T/bin:$PATH" "$d/scripts/check-deployment.sh"
t "sets the values and checks" 0 "every repository is an input" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" git@github.com:acme/catalog.git
k="$d/root/inputs.env"
check "deploymentRepoURL from origin, as https" grep -qx 'deploymentRepoURL=https://github.com/acme/deploy.git' "$k"
check "deploymentRevision main" grep -qx 'deploymentRevision=main' "$k"
check "catalogRepoURL from the argument, as https" grep -qx 'catalogRepoURL=https://github.com/acme/catalog.git' "$k"
check "catalogRevision main" grep -qx 'catalogRevision=main' "$k"
check "idpIssuerURL from the hub" grep -qx 'idpIssuerURL=https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants' "$k"
check "portalRedirectURI: a redirect for every site, space-separated" \
  grep -qx '  portalRedirectURI: https://maas.apps.site-i.example.com/\* https://maas.apps.site-c.example.com/\*' "$d/tenant-idp/manifests/settings.yaml"
check "  ... which the realm renders as one redirect URI each" bash -c '
  KEYCLOAK_CLIENT_SECRET=x TENANT_PORTAL_REDIRECT_URI=$(sed -n "s/^  portalRedirectURI: //p" "$1") \
    bash "$2/manifests/scripts/render-realm.sh" < "$2/manifests/realms/tenants-realm.json" |
    jq -e ".clients[0].redirectUris == [\"https://maas.apps.site-i.example.com/*\", \"https://maas.apps.site-c.example.com/*\"]" >/dev/null' _ \
  "$d/tenant-idp/manifests/settings.yaml" "$d/tenant-idp"
check "kustomization.yaml untouched" cmp -s "$T/kustomization-before" "$d/root/kustomization.yaml"
check "self.yaml untouched" cmp -s "$T/self-before" "$d/root/self.yaml"

# inputs.env renders the same root as the values written straight into the
# placeholders of kustomization.yaml and self.yaml (the layout before inputs).
old="$T/old-root"; cp -R "$d/root" "$old"; rm "$old/inputs.env"
python3 - "$old" <<'PY2'
import os, sys
d = sys.argv[1]
vals = {"deploymentRepoURL": "https://github.com/acme/deploy.git", "catalogRepoURL": "https://github.com/acme/catalog.git",
        "idpIssuerURL": "https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants"}
for name in ("kustomization.yaml", "self.yaml"):
    f = os.path.join(d, name); s = open(f).read()
    if "configMapGenerator:" in s:
        s = s[:s.index("configMapGenerator:")]
    out = []
    for line in s.split("\n"):
        if "op: test" not in line:
            for n, v in vals.items():
                line = line.replace("REQUIRED-" + n, v)
        out.append(line)
    open(f, "w").write("\n".join(out))
PY2
check "inputs.env renders byte for byte as values in the root's files" cmp -s <(oc kustomize "$d/root" || echo "new root failed") <(oc kustomize "$old" || echo "old root failed")
t "a second run keeps the values" 0 "kept +root/inputs.env: catalogRepoURL is already set" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/other.git
check "a second run changes nothing" grep -qx 'catalogRepoURL=https://github.com/acme/catalog.git' "$k"
# A site added to clusters.yaml after the first run gets its redirect; one of yours stays.
s="$d/tenant-idp/manifests/settings.yaml"
sed -i.bak 's#^  portalRedirectURI: \(.*\)$#  portalRedirectURI: \1 https://portal.example.com/*#' "$s"; rm "$s.bak"
printf "  - {name: site-n, api: 'https://api.site-n.example.com:6443'}\n" >> "$d/clusters.yaml"; mkdir -p "$d/.config/site-n"; : > "$d/.config/site-n/kubeconfig"
t "a new site's redirect is added" 0 "added +tenant-idp/manifests/settings.yaml: portalRedirectURI \+= https://maas.apps.site-n.example.com/\*$" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... after the ones there, yours kept" grep -qx '  portalRedirectURI: https://maas.apps.site-i.example.com/\* https://maas.apps.site-c.example.com/\* https://portal.example.com/\* https://maas.apps.site-n.example.com/\*' "$s"
sed -i.bak 's#^\(  portalRedirectURI: .*\)$#\1   \# every site#' "$s"; rm "$s.bak"
printf "  - {name: site-m, api: 'https://api.site-m.example.com:6443'}\n" >> "$d/clusters.yaml"; mkdir -p "$d/.config/site-m"; : > "$d/.config/site-m/kubeconfig"
t "a trailing comment: kept, and not taken for a redirect" 0 "added +tenant-idp/manifests/settings.yaml: portalRedirectURI \+= https://maas.apps.site-m.example.com/\*$" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... after the redirects, before the comment" grep -qx '  portalRedirectURI: https://maas.apps.site-i.example.com/\* https://maas.apps.site-c.example.com/\* https://portal.example.com/\* https://maas.apps.site-n.example.com/\* https://maas.apps.site-m.example.com/\*   # every site' "$s"
t "  ... once" 0 "kept +tenant-idp/manifests/settings.yaml: portalRedirectURI has every site's redirect" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog.git
sed -i.bak 's#^catalogRevision=.*#catalogRevision=release#' "$k"; rm "$k.bak"
t "a third run keeps a revision you changed" 0 "kept +root/inputs.env: catalogRevision is already set" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog.git
check "  ... and renders it" grep -q 'catalogRevision: release' <(oc kustomize "$d/root")
sed -i.bak 's#^idpIssuerURL=.*#idpIssuerURL=#' "$k"; rm "$k.bak"
t "an empty value is unset" 1 "unset inputs: idpIssuerURL" env PATH="$T/bin:$PATH" "$d/scripts/check-deployment.sh"
sed -i.bak '/^idpIssuerURL=/d' "$k"; rm "$k.bak"
t "a missing value fails the render" 1 "idpIssuerURL" env PATH="$T/bin:$PATH" "$d/scripts/check-deployment.sh"

d=$(repo https https://user@github.com/acme/deploy)
t "https origin: credentials dropped, .git added" 0 "deploymentRepoURL = https://github.com/acme/deploy.git$" \
  env PATH="$T/bin:$PATH" "$d/scripts/set-inputs.sh" https://github.com/acme/catalog

# With no argument, the catalog comes from clusters.yaml's catalog.url (make inputs).
d2=$(repo noarg https://github.com/acme/deploy.git)
t "no argument, page by page: names make inputs CATALOG=" 1 "run make inputs CATALOG=CATALOG_REPO_URL \(page 2\)" \
  env PATH="$T/bin:$PATH" "$d2/scripts/set-inputs.sh"
printf 'catalog:\n  url: git@github.com:acme/catalog2.git\n' >> "$d2/clusters.yaml"
t "no argument: reads catalog.url" 0 "every repository is an input" \
  env PATH="$T/bin:$PATH" "$d2/scripts/set-inputs.sh"
check "  ... and writes it as https" grep -qx 'catalogRepoURL=https://github.com/acme/catalog2.git' "$d2/root/inputs.env"
# With the private file, the error names its catalog.url.
d3=$(repo private https://github.com/acme/deploy.git); mv "$d3/clusters.yaml" "$d3/.config/clusters.yaml"; chmod 600 "$d3/.config/clusters.yaml"
t "no argument, private file: says where to set it" 1 "set catalog.url in .config/clusters.yaml" \
  env PATH="$T/bin:$PATH" "$d3/scripts/set-inputs.sh"
# Given a URL, set-inputs.sh doesn't read the settings, so a bad options: value can't stop it.
d4=$(repo opts https://github.com/acme/deploy.git); printf 'options:\n  GATE_READY_SECONDS: soon\n' >> "$d4/clusters.yaml"
t "a URL argument ignores the options: section" 0 "every repository is an input" \
  env PATH="$T/bin:$PATH" "$d4/scripts/set-inputs.sh" https://github.com/acme/catalog.git
t "two arguments: usage" 2 "usage: set-inputs.sh \[CATALOG_REPO_URL\]" env PATH="$T/bin:$PATH" "$d2/scripts/set-inputs.sh" a b

echo "set-inputs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
