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

repo() { # name site... -> a repository copy whose clusters.yaml has those sites (name, or name:role with the role unused), with logins
  local d="$T/$1"; shift; mkdir -p "$d/.config/hub"; cp -R "$SRC/scripts" "$SRC/Makefile" "$d/"; : > "$d/.config/hub/kubeconfig"
  { printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n'
    for s in "$@"; do printf '  - {name: %s, api: "https://api.%s.example.com:6443"}\n' "${s%:*}" "${s%:*}"
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
  *" get managedcluster "*) # site-b added as combined, site-c as inference; none with $STUB_LOG.not-added
    case "$3" in site-b) l=combined ;; site-c) l=inference ;; *) l="" ;; esac; [ ! -f "$STUB_LOG.not-added" ] || l=""
    echo "{\"metadata\":{\"labels\":{${l:+\"ai-grid/enabled\":\"true\",\"ai-grid/role\":\"$l\"}}},\"status\":{\"conditions\":[{\"type\":\"ManagedClusterJoined\",\"status\":\"True\"},{\"type\":\"ManagedClusterConditionAvailable\",\"status\":\"True\"}]}}" ;;
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

t "make help lists every guide target" 0 "console-secrets.*site-check.*site-detach.*site-wipe.*site-import.*site-status.*tenant-call.*uninstall-site.*uninstall-hub.*uninstall-check" \
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
touch "$STUB_LOG.not-added"; : > "$STUB_LOG"
t "site-status for a site not added yet: says so (role from its ManagedCluster labels)" 0 "^AI Grid: not added to the grid yet$" m "$one" site-status
t "  ... and no MaaS check" 0 "^ok$" bash -c '! grep -qE "ingresses.config|datasciencecluster" "$0" && echo ok' "$STUB_LOG"
rm "$STUB_LOG.not-added"
t "site-status names the role from its ManagedCluster labels" 0 "^AI Grid: added as combined$" m "$one" site-status
t "site-status with several sites lists them" 2 "name a site: site-b, site-c" m "$two" site-status
: > "$STUB_LOG"
t "site-status SITE= picks one" 0 "rhoai-site-c-x" m "$two" site-status SITE=site-c
t "  ... and skips the MaaS host for an inference site" 0 "^ok$" bash -c '! grep -q "ingresses.config" "$0" && echo ok' "$STUB_LOG"
t "a SITE that isn't a site is named" 2 "nope isn't a site in clusters.yaml: site-b, site-c" m "$two" site-status SITE=nope
for target in site-check site-import uninstall-site; do
  t "$target with several sites lists them" 2 "name a site: site-b, site-c" m "$two" "$target"
done

t "site-import previews by default" 0 "^ok$" bash -c 'out=$(make -n -C "$0" site-import); grep -q import-site.sh <<<"$out" && ! grep -q -- --yes <<<"$out" && echo ok' "$one"
t "site-import CONFIRM=1 imports" 0 "import-site.sh +--yes" make -n -C "$one" site-import CONFIRM=1
t "site-detach previews by default" 0 "detach-site.sh +--dry-run" make -n -C "$one" site-detach
t "site-detach CONFIRM=1 runs it" 0 "^ok$" bash -c 'out=$(make -n -C "$0" site-detach CONFIRM=1); grep -q detach-site.sh <<<"$out" && ! grep -q -- --dry-run <<<"$out" && echo ok' "$one"
t "site-detach SITE= passes the site" 0 "detach-site.sh --site site-c --dry-run" make -n -C "$two" site-detach SITE=site-c
t "site-wipe previews by default" 0 "wipe-site.sh +--dry-run" make -n -C "$one" site-wipe
t "site-wipe CONFIRM=1 runs it" 0 "^ok$" bash -c 'out=$(make -n -C "$0" site-wipe CONFIRM=1); grep -q wipe-site.sh <<<"$out" && ! grep -q -- --dry-run <<<"$out" && echo ok' "$one"
t "site-wipe SITE= passes the site" 0 "wipe-site.sh --site site-c --dry-run" make -n -C "$two" site-wipe SITE=site-c
t "uninstall-site previews by default" 0 "uninstall.sh site .* --dry-run" make -n -C "$one" uninstall-site
t "uninstall-site CONFIRM=1 keeps a plan file" 0 '--plan-file "\.uninstall/\$n-plan\.tsv"' make -n -C "$one" uninstall-site CONFIRM=1
t "uninstall-hub previews by default" 0 "uninstall.sh hub --dry-run" make -n -C "$one" uninstall-hub
t "site-join is gone (Add to AI Grid in the provider console)" 2 "No rule to make target" make -n -C "$one" site-join
t "join is gone too" 2 "No rule to make target" make -n -C "$one" join
t "make help lists no join target" 0 "^ok$" bash -c '! make -s -C "$0" help | grep -q "join" && echo ok' "$one"
t "site-add is gone (no certificate step)" 2 "No rule to make target" make -n -C "$one" site-add
t "tenant-call needs KEY_FILE" 2 "set KEY_FILE, such as: make tenant-call KEY_FILE=KEY_FILE" make -s -C "$one" tenant-call MODEL=m
t "tenant-call needs MODEL" 2 "set MODEL, such as: make tenant-call MODEL=MODEL_NAME" make -s -C "$one" tenant-call KEY_FILE=k
t "tenant-call SITE= and SUBSCRIPTION= pass through" 0 "--key-file \"k\" --model \"m\" --subscription \"s\".*--site site-c" \
  make -n -C "$two" tenant-call KEY_FILE=k MODEL=m SUBSCRIPTION=s SITE=site-c
t "no tenant-user target: the library Keycloak's users are brokered" 2 "No rule to make target" make -s -C "$one" tenant-user

t "make install runs scripts/install.sh" 0 "^scripts/install.sh *$" make -n -C "$one" install
t "make provider-admin runs scripts/provider-admin.sh" 0 "^scripts/provider-admin.sh$" make -n -C "$one" provider-admin
: > "$STUB_LOG"
t "make ready-check is read-only" 0 "^ok$" bash -c 'PATH="$1:$PATH" make -s -C "$0" ready-check >/dev/null 2>&1;
  grep -q "get " "$2" && ! grep -E " oc (apply|create|patch|delete|label)" "$2" && echo ok' "$one" "$T/bin" "$STUB_LOG"
t "make secrets is gone (edit .config/clusters.yaml)" 2 "No rule to make target" make -n -C "$one" secrets
t "make help doesn't list secrets" 0 "^ok$" bash -c '! make -s -C "$0" help | grep -q "^secrets:" && echo ok' "$one"
t "make install HUB_ONLY=1 runs --hub-only" 0 "scripts/install.sh --hub-only" make -n -C "$one" install HUB_ONLY=1
t "make help lists install" 0 "^install: Install the hub and import every site, unattended \(page 9\); HUB_ONLY=1 for the hub alone$" make -s -C "$one" help
t "make login NONINTERACTIVE=1 passes --non-interactive" 0 "^scripts/login.sh --non-interactive *$" make -n -C "$one" login NONINTERACTIVE=1
t "make login without it: unchanged" 0 "^scripts/login.sh *$" make -n -C "$one" login

t "make help lists inputs, check and console-call" 0 "inputs:.*check:.*console-call:" bash -c 'make -s -C "$0" help | tr "\n" " "' "$one"
t "make help marks test for maintainers" 0 "^test: .*for maintainers" make -s -C "$one" help
t "make help lists test-upstream, against the library's current main" 0 "^test-upstream: .*current main" make -s -C "$one" help
t "make test-upstream runs the library-reading tests at main" 0 "for t in tests/root-selection-test.sh tests/deployment-scripts-test.sh; do TEST_LIBRARY_REVISION=main bash" \
  bash -c 'make -n -C "$0" test-upstream | tr "\n" " "' "$one"
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
t "make help: CATALOG for page 2, make install reads catalog.url" 0 "^inputs: .*CATALOG=URL \(page 2\); make install reads catalog.url$" make -s -C "$one" help

# make config: only creates the private file from the example, never overwrites it.
# From the example, the private file has the secrets make install needs uncommented, as REQUIRED- placeholders.
cfg="$T/config"; mkdir -p "$cfg"; cp -R "$SRC/Makefile" "$SRC/clusters-example.yaml" "$SRC/scripts" "$cfg/"
t "make config: creates .config/clusters.yaml from the example" 0 "Created .config/clusters.yaml from clusters-example.yaml.*REQUIRED-" make -s -C "$cfg" config
for line in '  username: REQUIRED-hubUsername' '  password: REQUIRED-hubPassword' \
    '    username: REQUIRED-siteUsername' '    password: REQUIRED-sitePassword' '  token: REQUIRED-catalogToken' \
    'quay:' '  username: REQUIRED-quayUsername' '  password: REQUIRED-quayPassword' \
    'stage:' '  username: REQUIRED-stageUsername' '  password: REQUIRED-stagePassword'; do
  t "  ... uncommented: ${line# *}" 0 . grep -xF -- "$line" "$cfg/.config/clusters.yaml"
done
t "  ... the token alternatives stay commented" 0 "^2$" bash -c 'grep -cE "^ +# token: sha256~TOKEN$" "$0"; ! grep -qE "^ +token: sha256" "$0"' "$cfg/.config/clusters.yaml"
t "  ... deployment: stays commented" 0 "^ok$" bash -c 'grep -qx "# deployment:" "$0" && grep -qx "#   token: github_pat_TOKEN" "$0" && ! grep -q "^deployment:" "$0" && echo ok' "$cfg/.config/clusters.yaml"
t "  ... the rest is the example's" 0 "^ok$" bash -c 'diff <(grep -v REQUIRED- "$0/clusters-example.yaml" | grep -vxE "# (quay|stage):|#   (username|password): (rhoai\+robot|STAGE_USERNAME|PASSWORD)|  +# (username|password): (kubeadmin|PASSWORD)|  # token: github_pat_TOKEN") <(grep -v REQUIRED- "$0/.config/clusters.yaml" | grep -vxE "(quay|stage):") && echo ok' "$cfg"
t "  ... parses, and the loader names each secret left to set" 0 "^ok$" bash -c 'out=$(bash "$0/scripts/clusters.sh" --rows "$0" 2>&1); for k in hub.username hub.password "sites\[0\].username" "sites\[0\].password" catalog.token quay.username quay.password stage.username stage.password; do grep -qE "set these in .config/clusters.yaml: .* $k( |$)" <<<"$out" || { echo "no $k in: $out"; exit 1; }; done; echo ok' "$cfg"
t "  ... .config mode 700, the file mode 600" 0 "^700600$" bash -c 'for f in "$0/.config" "$0/.config/clusters.yaml"; do stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f"; done | tr -d "\n"' "$cfg"
echo "mine" >> "$cfg/.config/clusters.yaml"
t "make config again: refuses" 2 "already exists" make -s -C "$cfg" config
t "  ... the file kept" 0 "^mine$" tail -n1 "$cfg/.config/clusters.yaml"
cfg2="$T/config-root"; mkdir -p "$cfg2"; cp "$SRC/Makefile" "$SRC/clusters-example.yaml" "$cfg2/"; echo "# ours" > "$cfg2/clusters.yaml"
t "make config with a clusters.yaml: copies that one" 0 "^ok$" bash -c 'out=$(make -s -C "$0" config) && grep -q "Copied clusters.yaml" <<<"$out" && cmp -s "$0/clusters.yaml" "$0/.config/clusters.yaml" && echo ok' "$cfg2"

echo "make-targets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
