#!/usr/bin/env bash
# Tests for the Makefile's install-guide targets: which site each one uses (the
# only site, SITE=, or a stop with the list), the preview-by-default targets,
# the required variables, and site-status against a stub oc.
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

repo() { # name site... -> a repository copy whose clusters.yaml has those sites (name:role), with logins
  local d="$T/$1"; shift; mkdir -p "$d/.config/hub"; cp -R "$SRC/scripts" "$SRC/Makefile" "$d/"; : > "$d/.config/hub/kubeconfig"
  { printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n'
    for s in "$@"; do printf '  - {name: %s, role: %s, location: us-east, api: "https://api.%s.example.com:6443"}\n' "${s%:*}" "${s#*:}" "${s%:*}"
      mkdir -p "$d/.config/${s%:*}"; : > "$d/.config/${s%:*}/kubeconfig"; done; } > "$d/clusters.yaml"
  echo "$d"
}

# The stub oc logs KUBECONFIG and its arguments, and answers site-status's reads.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
echo "$(basename "$(dirname "$KUBECONFIG")") oc $*" >> "$STUB_LOG"
case " $* " in
  *" whoami "*) echo admin ;;
  *" get managedcluster "*) echo '{"status":{"conditions":[{"type":"ManagedClusterJoined","status":"True"},{"type":"ManagedClusterConditionAvailable","status":"True"}]}}' ;;
  *" get applications.argoproj.io "*) echo '{"items":[{"metadata":{"name":"rhoai-site-b-x"},"spec":{"destination":{"name":"site-b"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}},{"metadata":{"name":"rhoai-site-c-x"},"spec":{"destination":{"name":"site-c"}},"status":{"sync":{"status":"OutOfSync"},"health":{"status":"Missing"}}}]}' ;;
  *" get ingresses.config.openshift.io "*) echo apps.example.invalid ;;
  *" get managedclusteraddons.addon.open-cluster-management.io "*) cat "$STUB_LOG.addons" 2>/dev/null || echo '{"items":[]}' ;;
  *" get ns -o jsonpath="*) cat "$STUB_LOG.terminating" 2>/dev/null; true ;;
  *" get datasciencecluster "*) [ -f "$STUB_LOG.no-dsc" ] || echo datasciencecluster.datasciencecluster.opendatahub.io/default-dsc ;;
  *" get llminferenceservices,"*) echo "NAMESPACE   NAME           READY"; echo "models      smollm2-chat   True" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
# The stub curl can't reach the host (exit 6), or with STUB_CURL_CERT=1 fails as
# on a certificate it doesn't trust (exit 60, as curl does).
printf '#!/bin/bash\nif [ -n "${STUB_CURL_CERT:-}" ]; then echo 000; echo "curl: (60) SSL certificate problem: self-signed certificate in certificate chain" >&2; exit 60; fi\necho 000\nexit 6\n' > "$T/bin/curl"
chmod +x "$T/bin/oc" "$T/bin/curl"
export STUB_LOG="$T/oc.log"
m() { env PATH="$T/bin:$PATH" make -s -C "$@"; }

one=$(repo one site-b:combined)
two=$(repo two site-b:combined site-c:inference)

t "make help lists every guide target" 0 "console-secrets.*site-check.*site-wipe.*site-import.*site-join.*site-status.*tenant-user.*tenant-call.*uninstall-site.*uninstall-hub.*uninstall-check" \
  bash -c 'make -s -C "$0" help | tr "\n" " "' "$one"

: > "$STUB_LOG"
t "site-status with one site uses it" 0 "ManagedCluster: JOINED=True AVAILABLE=True" m "$one" site-status
t "  ... lists its hub Applications only" 0 "^ok$" bash -c 'out=$(PATH="$1:$PATH" make -s -C "$0" site-status 2>&1); grep -q rhoai-site-b-x <<<"$out" && ! grep -q rhoai-site-c-x <<<"$out" && echo ok' "$one" "$T/bin"
t "  ... reads the MaaS host and the site's models" 0 "smollm2-chat" m "$one" site-status
t "  ... a MaaS gateway with the internal certificate: says so, not an error code" 0 \
  "^MaaS https://maas\.[^ ]+/v1/models: answers with the cluster's internal certificate, which isn't publicly trusted$" \
  env STUB_CURL_CERT=1 PATH="$T/bin:$PATH" make -s -C "$one" site-status
t "  ... and only reads" 0 "^ok$" bash -c '! grep -E " oc (apply|label|patch|delete|create)" "$0" && echo ok' "$STUB_LOG"
echo '{"items":[{"metadata":{"name":"submariner"},"status":{"conditions":[{"type":"ManifestApplied","status":"False","message":"namespace submariner-operator is being terminated"}]}},{"metadata":{"name":"work-manager"},"status":{"conditions":[{"type":"ManifestApplied","status":"True","message":"ok"}]}}]}' > "$STUB_LOG.addons"
printf 'some-app\nsubmariner-operator\n' > "$STUB_LOG.terminating"
t "site-status flags an add-on whose manifests aren't applied" 0 "^  !! ManagedClusterAddOn submariner: ManifestApplied=False: namespace submariner-operator is being terminated$" m "$one" site-status
t "  ... and only that one" 0 "^ok$" bash -c '! PATH="$1:$PATH" make -s -C "$0" site-status 2>&1 | grep -q "work-manager" && echo ok' "$one" "$T/bin"
t "site-status flags an install namespace in Terminating" 0 "^  !! Namespace submariner-operator is Terminating$" m "$one" site-status
t "  ... not another one" 0 "^ok$" bash -c '! PATH="$1:$PATH" make -s -C "$0" site-status 2>&1 | grep -q "some-app" && echo ok' "$one" "$T/bin"
rm "$STUB_LOG.addons" "$STUB_LOG.terminating"
touch "$STUB_LOG.no-dsc"; : > "$STUB_LOG"
t "site-status before OpenShift AI: MaaS not installed yet" 0 "^MaaS: not installed yet \(page 6\)$" m "$one" site-status
t "  ... and no HTTP check" 0 "^ok$" bash -c '! grep -q "ingresses.config" "$0" && echo ok' "$STUB_LOG"
rm "$STUB_LOG.no-dsc"
t "site-status with several sites lists them" 2 "name a site: site-b, site-c" m "$two" site-status
: > "$STUB_LOG"
t "site-status SITE= picks one" 0 "rhoai-site-c-x" m "$two" site-status SITE=site-c
t "  ... and skips the MaaS host for an inference site" 0 "^ok$" bash -c '! grep -q "ingresses.config" "$0" && echo ok' "$STUB_LOG"
t "a SITE that isn't a site is named" 2 "nope isn't a site in clusters.yaml: site-b, site-c" m "$two" site-status SITE=nope
for target in site-check site-import site-join uninstall-site; do
  t "$target with several sites lists them" 2 "name a site: site-b, site-c" m "$two" "$target"
done

t "site-import previews by default" 0 "^ok$" bash -c 'out=$(make -n -C "$0" site-import); grep -q import-site.sh <<<"$out" && ! grep -q -- --yes <<<"$out" && echo ok' "$one"
t "site-import CONFIRM=1 imports" 0 "import-site.sh +--yes" make -n -C "$one" site-import CONFIRM=1
t "site-wipe previews by default" 0 "wipe-site.sh +--dry-run" make -n -C "$one" site-wipe
t "site-wipe CONFIRM=1 runs it" 0 "^ok$" bash -c 'out=$(make -n -C "$0" site-wipe CONFIRM=1); grep -q wipe-site.sh <<<"$out" && ! grep -q -- --dry-run <<<"$out" && echo ok' "$one"
t "site-wipe SITE= passes the site" 0 "wipe-site.sh --site site-c --dry-run" make -n -C "$two" site-wipe SITE=site-c
t "uninstall-site previews by default" 0 "uninstall.sh site .* --dry-run" make -n -C "$one" uninstall-site
t "uninstall-site CONFIRM=1 keeps a plan file" 0 '--plan-file "\.uninstall/\$n-plan\.tsv"' make -n -C "$one" uninstall-site CONFIRM=1
t "uninstall-hub previews by default" 0 "uninstall.sh hub --dry-run" make -n -C "$one" uninstall-hub
t "site-add is gone (no certificate step)" 2 "No rule to make target" make -n -C "$one" site-add
t "tenant-user needs ORG" 2 "set ORG, such as: make tenant-user ORG=ORG_NAME" make -s -C "$one" tenant-user
t "tenant-call needs MODEL" 2 "set MODEL, such as: make tenant-call MODEL=MODEL_NAME" \
  make -s -C "$one" tenant-call TENANT_USER=u PASSWORD_FILE=p SUBSCRIPTION=s
t "tenant-call SITE= passes --site" 0 "--site site-c" make -n -C "$two" tenant-call TENANT_USER=u PASSWORD_FILE=p SUBSCRIPTION=s MODEL=m SITE=site-c
t "tenant-user uses the hub's login" 0 'kubeconfig "\.config/\$\(scripts/clusters\.sh --hub\)/kubeconfig"' \
  make -n -C "$one" tenant-user ORG=o TENANT_USER=u PASSWORD_FILE=p

t "make install runs scripts/install.sh" 0 "^scripts/install.sh *$" make -n -C "$one" install
t "make provider-admin runs scripts/provider-admin.sh" 0 "^scripts/provider-admin.sh$" make -n -C "$one" provider-admin
: > "$STUB_LOG"
t "make ready-check is read-only" 0 "^ok$" bash -c 'PATH="$1:$PATH" make -s -C "$0" ready-check >/dev/null 2>&1;
  grep -q "get " "$2" && ! grep -E " oc (apply|create|patch|delete|label)" "$2" && echo ok' "$one" "$T/bin" "$STUB_LOG"
t "make help lists secrets" 0 "^secrets: Ask for each cluster's token or username and password" make -s -C "$one" help
t "make install HUB_ONLY=1 runs --hub-only" 0 "scripts/install.sh --hub-only" make -n -C "$one" install HUB_ONLY=1
t "make help lists install" 0 "^install: Install the hub and import every site, unattended \(page 9\); HUB_ONLY=1 for the hub alone$" make -s -C "$one" help
t "make login NONINTERACTIVE=1 passes --non-interactive" 0 "^scripts/login.sh --non-interactive *$" make -n -C "$one" login NONINTERACTIVE=1
t "make login without it: unchanged" 0 "^scripts/login.sh *$" make -n -C "$one" login

t "make help lists inputs, check and console-call" 0 "inputs:.*check:.*console-call:" bash -c 'make -s -C "$0" help | tr "\n" " "' "$one"
t "make help marks test for maintainers" 0 "^test: .*for maintainers" make -s -C "$one" help
t "make inputs runs set-inputs.sh with no argument" 0 "^scripts/set-inputs.sh *$" make -n -C "$one" inputs
t "make inputs CATALOG= passes it" 0 "^scripts/set-inputs.sh 'https://github.com/acme/cat.git' *$" make -n -C "$one" inputs CATALOG=https://github.com/acme/cat.git
t "make check runs check-deployment.sh" 0 "^scripts/check-deployment.sh *$" make -n -C "$one" check
t "console-call needs METHOD" 2 "set METHOD, such as: make console-call METHOD=ai_grid.v1.Tenants/List" make -s -C "$one" console-call
t "console-call: BODY and BODY_FILE together stop" 2 "set BODY or BODY_FILE, not both" make -s -C "$one" console-call METHOD=m BODY='{}' BODY_FILE=f
# A copy whose console-call.sh prints its arguments, one per line, to run the target for real.
cc=$(repo cc site-b:combined); printf '#!/bin/bash\nprintf "[%%s]\\n" "$@"\n' > "$cc/scripts/console-call.sh"
t "console-call with no BODY sends an empty one, which console-call.sh makes {}" 0 "^ok$" bash -c 'out=$(make -s -C "$0" console-call METHOD=m); [ "$out" = "$(printf "[m]\n[]")" ] && echo ok' "$cc"
t "console-call BODY= passes it" 0 '^\[\{"a":1\}\]$' make -s -C "$cc" console-call METHOD=m 'BODY={"a":1}'
printf '{"b":2}' > "$T/body.json"
t "console-call BODY_FILE= passes the file's contents" 0 '^\[\{"b":2\}\]$' make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/body.json"
printf '%s' '{"a":"it'"'"'s"}' > "$T/quote-body"
t "console-call BODY with a single quote stays one word" 0 "^ok$" bash -c 'want=$(cat "$1"); out=$(make -s -C "$0" console-call METHOD=m BODY="$want"); [ "$out" = "[m]"$'"'"'\n'"'"'"[$want]" ] && echo ok' "$cc" "$T/quote-body"
printf '{\n  "name": "acme",\n  "domains": ["acme.example.com"]\n}' > "$T/multi-body"
t "console-call BODY on several lines arrives whole" 0 "^ok$" bash -c 'want=$(cat "$1"); out=$(make -s -C "$0" console-call METHOD=m BODY="$want"); [ "$out" = "[m]"$'"'"'\n'"'"'"[$want]" ] && echo ok' "$cc" "$T/multi-body"
printf '%s' '{"a":"$HOME x$$y"}' > "$T/dollar-body"
t "console-call BODY_FILE keeps a \$ as it is" 0 '^\[\{"a":"\$HOME x\$\$y"\}\]$' make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/dollar-body"
t "console-call BODY from the environment keeps a \$ as it is" 0 '^\[\{"a":"\$HOME x\$\$y"\}\]$' env BODY='{"a":"$HOME x$$y"}' make -s -C "$cc" console-call METHOD=m
mkdir -p "$T/a b"; printf '{"b":3}' > "$T/a b/x.json"
t "console-call BODY_FILE with a space in its path is read" 0 '^\[\{"b":3\}\]$' make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/a b/x.json"
t "console-call BODY_FILE that doesn't exist stops" 2 "can't read BODY_FILE $T/nope.json \(missing or empty\)" make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/nope.json"
: > "$T/empty.json"
t "console-call BODY_FILE that's empty stops, not sends {}" 2 "can't read BODY_FILE $T/empty.json \(missing or empty\)" make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/empty.json"
mkdir -p "$T/q\"d"; printf '{}' > "$T/q\"d/x.json"
t "console-call BODY_FILE with a double quote in its path is read" 0 '^\[\{\}\]$' make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/q\"d/x.json"
t "console-call BODY_FILE missing, with a double quote in its path, names it" 2 'BODY_FILE .*/q"d/nope.json \(missing' make -s -C "$cc" console-call METHOD=m BODY_FILE="$T/q\"d/nope.json"
t "make help: CATALOG for page 2, make install reads repositories.catalog" 0 "^inputs: .*CATALOG=URL \(page 2\); make install reads repositories.catalog$" make -s -C "$one" help

echo "make-targets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
