#!/usr/bin/env bash
# Exercises scripts/prereqs.py against stub tools and a stub oc (no cluster, no
# registry). PATH holds only the stubs and python3, so the host's tools don't count.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/prereqs.py"
PY=$(command -v python3); GIT=$(command -v git)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# A stand-in library checkout with the pinned catalog image, as git repository.
LIBD="$T/library"; mkdir -p "$LIBD/apps/rhoai"
printf 'image:\n  registry: quay.io\n  repository: rhoai/rhoai-fbc-fragment\n  tag: rhoai-3.6@sha256:%064d\n' 0 > "$LIBD/apps/rhoai/nightly.yaml"
"$GIT" -C "$LIBD" init -q && "$GIT" -C "$LIBD" add -A && "$GIT" -C "$LIBD" -c user.name=t -c user.email=t@example.com commit -qm library
TOKEN=c3R1Yi11c2VyOkZBS0VfVE9LRU5fZG9fbm90X3ByaW50XzQyNDI0Mg==   # base64 of stub-user:FAKE_TOKEN_do_not_print_424242
PASSWORD=FAKE_TOKEN_do_not_print_424242

# Every stub uses only bash builtins: PATH has nothing else on it.
mkbin() { # dir: a bin dir with every tool stubbed
  local b=$1; mkdir -p "$b"; ln -sf "$PY" "$b/python3"
  # git answers --version itself and passes rev-parse on to the real git.
  printf '#!/bin/bash\n[ "$1" = --version ] && { echo "git version 1.2.3"; exit; }\nexec %s "$@"\n' "$GIT" > "$b/git"
  # kubectl and jq answer --version themselves and pass the rest to the real ones (clusters.yaml).
  for t in kubectl jq; do
    printf '#!/bin/bash\ncase "$1" in version|--version) echo "%s 1.2.3"; exit ;; esac\nexec %s "$@"\n' "$t" "$(command -v "$t")" > "$b/$t"
  done
  for t in curl openssl base64 clusteradm make; do
    printf '#!/bin/bash\necho "%s 1.2.3"\n' "$t" > "$b/$t"
  done
  # The stub oc logs its arguments and answers from files in $STUB_DIR; a
  # missing file is an empty answer. A file "fail-<verb>" makes that call fail.
  cat > "$b/oc" <<'END_STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/argv.log"; args=" $* "
answer() { [ -f "$d/$1" ] && echo "$(<"$d/$1")"; return 0; }
case "$args" in
  *" version --client "*) echo "Client Version: 4.22.17" ;;
  *" whoami --show-server "*) [ -f "$d/fail-whoami" ] && { echo "error: Unauthorized" >&2; exit 1; }; echo https://api.stub:6443 ;;
  *" get clusterversion version "*) answer version ;;
  *" auth can-i "*) answer can-i ;;
  *" get storageclasses."*) answer storageclasses.json ;;
  *" get clusterissuers."*) [ -f "$d/fail-issuers" ] && { echo 'error: the server doesn'"'"'t have a resource type "clusterissuers"' >&2; exit 1; }; answer clusterissuers.json ;;
  *" image info "*)
    [ -f "$d/fail-image" ] && { echo "error: unauthorized: access to the requested resource is not authorized (auth $(<"$d/leak"))" >&2; exit 1; }
    echo "Name: quay.io/rhoai/rhoai-fbc-fragment" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
END_STUB
  for f in "$b"/*; do [ -L "$f" ] || chmod 755 "$f"; done
}

world() { # name: a fresh stub cluster that passes every check
  local w="$T/$1"; rm -rf "$w"; mkdir -p "$w"
  echo "4.22.18" > "$w/version"; echo yes > "$w/can-i"
  echo '{"items":[{"metadata":{"name":"gp3-csi","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}' > "$w/storageclasses.json"
  echo '{"items":[{"metadata":{"name":"le-dns"},"spec":{"acme":{"solvers":[{"dns01":{"route53":{}}}]}}}]}' > "$w/clusterissuers.json"
  echo "$TOKEN" > "$w/leak"
  echo "$w"
}

authfile() { # name, keys...: an auth file with these registries, each holding the fake token
  local f="$T/$1.json"; shift; local sep="" body=""
  for k in "$@"; do body="$body$sep\"$k\":{\"auth\":\"$TOKEN\"}"; sep=,; done
  echo "{\"auths\":{$body}}" > "$f"; echo "$f"
}

mkbin "$T/bin"
fails=0; total=0
t() { # name expect_regex bin world [args...]; also checks rc 0 and no secret in the output
  local name=$1 expect=$2 bin=$3 w=$4; shift 4; local rc out
  total=$((total+1))
  out=$(env -i LIBRARY="$LIBD" PATH="$bin" HOME="$T" STUB_DIR="$w" "$PY" "$SCRIPT" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && grep -qE -- "$expect" <<<"$out" && ! grep -qE "$TOKEN|$PASSWORD" <<<"$out"; then
    printf '   ok   %s\n' "$name"
  else
    printf '   FAIL %s (rc=%s; output:)\n%s\n' "$name" "$rc" "$out"; fails=$((fails+1))
  fi
}

w=$(world all-ok); A=$(authfile both quay.io/rhoai registry.stage.redhat.io)
TOK="$T/token"; printf 'x' > "$TOK"; chmod 600 "$TOK"
mkdep() { # name clusters-body: a deployment at the pin with that clusters.yaml and a login for each cluster
  local d="$T/$1"; mkdir -p "$d/root"
  printf '        libraryRevision: %s\n' "$("$GIT" -C "$LIBD" rev-parse HEAD)" > "$d/root/kustomization.yaml"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\n%b\n' "$2" > "$d/clusters.yaml"
  for n in $(grep -oE 'name: [a-z0-9-]+' "$d/clusters.yaml" | cut -d' ' -f2); do mkdir -p "$d/.config/$n"; : > "$d/.config/$n/kubeconfig"; done
  echo "$d"
}
D=$(mkdep deployment "hub: {name: hub, api: 'https://api.hub:6443'}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: 'https://api.site-b:6443'}")
ALL=(--deployment "$D" --quay-auth-file "$A" --catalog-token-file "$TOK")
t "all ok: no problem lines" '^[0-9]+ ok$' "$T/bin" "$w" "${ALL[@]}"
t "all ok: site ClusterIssuer with DNS-01" '^ok +ClusterIssuer +le-dns \(DNS-01\)' "$T/bin" "$w" "${ALL[@]}"
t "all ok: catalog pulls" '^ok +pull the pinned catalog +quay.io/rhoai/rhoai-fbc-fragment' "$T/bin" "$w" "${ALL[@]}"
if grep -qE "$TOKEN|$PASSWORD" "$w/argv.log"; then echo "   FAIL a secret reached oc's argv"; fails=$((fails+1)); else echo "   ok   no secret on oc's argv"; fi
if grep -qwE 'apply|create|delete|patch|edit|label|annotate|replace|scale' "$w/argv.log"; then
  echo "   FAIL oc got a write verb"; fails=$((fails+1)); else echo "   ok   oc calls are read-only"; fi
total=$((total+2))

t "library at the pin" '^ok +library at your pin' "$T/bin" "$w" "${ALL[@]}"
mkdir -p "$T/other/root"; echo "  libraryRevision: 0123456789abcdef0123456789abcdef01234567" > "$T/other/root/kustomization.yaml"
t "library not at the pin" '^FAIL +library at your pin +.* not 0123456789ab: git -C ' "$T/bin" "$w" --deployment "$T/other"
keep=$LIBD; LIBD="$T/no-library"
t "library not cloned" '^FAIL +library at your pin +no library checkout at .*no-library: run scripts/library.sh' "$T/bin" "$w" "${ALL[@]}"
LIBD=$keep

mkbin "$T/nojq"; rm "$T/nojq/jq"
t "missing tool" '^MISSING +jq ' "$T/nojq" "$w"
t "missing tool: summary and note" 'Nothing was changed' "$T/nojq" "$w"

t "nothing set: registry skipped" '^skipped +registry logins +no auth file at ~/.config/containers/auth.json.*; set QUAY_AUTH_FILE' "$T/bin" "$w"
t "no clusters.yaml: skipped" '^skipped +cluster checks +no clusters.yaml: copy clusters-example.yaml' "$T/bin" "$w" --deployment "$T/other"
P=$(mkdep placeholder 'hub: {name: hub, api: REQUIRED-hubAPIURL}')
t "clusters placeholder: skipped" '^skipped +cluster checks +.*REQUIRED-hubAPIURL' "$T/bin" "$w" --deployment "$P"
t "site section named" '^Site site-b \(combined\)' "$T/bin" "$w" "${ALL[@]}"
t "nothing set: token skipped" '^skipped +catalog token file' "$T/bin" "$w"

t "quay.io/rhoai and stage" '^ok +registry.stage.redhat.io login' "$T/bin" "$w" --quay-auth-file "$A"
G=$(authfile generic quay.io registry.stage.redhat.io)
t "general quay.io login: ok with the note" '^ok +quay.io/rhoai login +general quay.io entry: page 3 needs RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1' "$T/bin" "$w" --quay-auth-file "$G"
N=$(authfile nostage quay.io/rhoai)
t "no stage login" '^MISSING +registry.stage.redhat.io login +page 7.s model runtime .*registry.redhat.io/rhaii.* add this login to the auth file before page 3' "$T/bin" "$w" --quay-auth-file "$N"
O=$(authfile other docker.io)
t "no quay login" '^MISSING +quay.io/rhoai login' "$T/bin" "$w" --quay-auth-file "$O"
t "auth file not found" '^MISSING +auth file' "$T/bin" "$w" --quay-auth-file "$T/nope.json"
touch "$w/fail-image"
t "registry refuses: FAIL, token scrubbed" '^FAIL +pull the pinned catalog +.*unauthorized' "$T/bin" "$w" --quay-auth-file "$A"
rm "$w/fail-image"

w=$(world old); echo "4.20.5" > "$w/version"; echo no > "$w/can-i"
echo '{"items":[{"metadata":{"name":"gp2"}}]}' > "$w/storageclasses.json"
t "OpenShift 4.20 is OLD" '^OLD +OpenShift 4.21 or later +4.20.5' "$T/bin" "$w" --deployment "$D"
t "not cluster-admin" '^MISSING +cluster-admin' "$T/bin" "$w" --deployment "$D"
t "no default StorageClass" '^MISSING +default StorageClass' "$T/bin" "$w" --deployment "$D"
echo '{"items":[{"metadata":{"name":"self-signed"},"spec":{"selfSigned":{}}}]}' > "$w/clusterissuers.json"
t "ClusterIssuer without DNS-01" '^MISSING +ClusterIssuer +self-signed \(no DNS-01\)' "$T/bin" "$w" --deployment "$D"
touch "$w/fail-issuers"
t "no cert-manager" '^MISSING +ClusterIssuer +error: the server' "$T/bin" "$w" --deployment "$D"
touch "$w/fail-whoami"
t "unreachable cluster" '^FAIL +reachable +hub: error: Unauthorized' "$T/bin" "$w" --deployment "$D"
t "unreachable cluster skips the rest" '^skipped +cluster-admin +cluster not reachable' "$T/bin" "$w" --deployment "$D"
rm "$D/.config/site-b/kubeconfig"
t "no login: skipped with the fix" '^skipped +site-b checks +no login: run make login NAME=site-b' "$T/bin" "$w" --deployment "$D"

printf 'x' > "$T/loose"; chmod 644 "$T/loose"; : > "$T/empty"; chmod 600 "$T/empty"
t "token file too open" '^FAIL +catalog token file +.* mode 644' "$T/bin" "$w" --catalog-token-file "$T/loose"
t "token file empty" '^FAIL +catalog token file +.* empty' "$T/bin" "$w" --catalog-token-file "$T/empty"
t "token file missing" '^MISSING +catalog token file' "$T/bin" "$w" --catalog-token-file "$T/none"
out=$(env -i LIBRARY="$LIBD" PATH="$T/bin" HOME="$T" STUB_DIR="$w" CATALOG_TOKEN_FILE="$TOK" "$PY" "$SCRIPT" 2>&1) || true
total=$((total+1)); if grep -qE '^ok +catalog token file' <<<"$out"; then echo "   ok   env vars work like options"; else echo "   FAIL env vars work like options"; fails=$((fails+1)); fi

# Defaults: the usual auth file and token file, when they exist and nothing is set.
dflt() { # name expect_regex home [VAR=value ...]: runs with no options from that home
  local name=$1 expect=$2 h=$3; shift 3; total=$((total+1))
  local out; out=$(env -i LIBRARY="$LIBD" PATH="$T/bin" HOME="$h" STUB_DIR="$w" "$@" "$PY" "$SCRIPT" 2>&1) || true
  if grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"; else echo "   FAIL $name; output:"; echo "$out"; fails=$((fails+1)); fi
}
H1="$T/home1"; mkdir -p "$H1/.config/containers" "$H1/.ai-grid" "$T/run1/containers"
cp "$A" "$H1/.config/containers/auth.json"; cp "$A" "$T/run1/containers/auth.json"
printf 'x' > "$H1/.ai-grid/catalog-token"; chmod 600 "$H1/.ai-grid/catalog-token"
dflt "default auth file: ~/.config/containers/auth.json" "^ok +auth file +$H1/.config/containers/auth.json" "$H1" XDG_RUNTIME_DIR="$T/run1"
dflt "default token file: ~/.ai-grid/catalog-token" "^ok +catalog token file +$H1/.ai-grid/catalog-token" "$H1"
dflt "an empty variable uses the default" "^ok +auth file +$H1/.config/containers/auth.json" "$H1" QUAY_AUTH_FILE= CATALOG_TOKEN_FILE=
dflt "QUAY_AUTH_FILE beats the default" "^ok +auth file +$N" "$H1" QUAY_AUTH_FILE="$N"
H2="$T/home2"; mkdir -p "$H2"
dflt "fallback auth file: \$XDG_RUNTIME_DIR/containers/auth.json" "^ok +auth file +$T/run1/containers/auth.json" "$H2" XDG_RUNTIME_DIR="$T/run1"
dflt "no default token file: skipped" '^skipped +catalog token file +no ~/.ai-grid/catalog-token yet' "$H2"

echo "prereqs tests: $((total-fails)) ok, $fails failed"; exit "$fails"
