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
printf '#!/bin/bash\necho 000\nexit 6\n' > "$T/bin/curl"
chmod +x "$T/bin/oc" "$T/bin/curl"
export STUB_LOG="$T/oc.log"
m() { env PATH="$T/bin:$PATH" make -s -C "$@"; }

one=$(repo one site-b:combined)
two=$(repo two site-b:combined site-c:inference)

t "make help lists every guide target" 0 "console-secrets.*site-check.*site-wipe.*site-import.*site-add.*site-join.*site-status.*tenant-user.*tenant-call.*uninstall-site.*uninstall-hub.*uninstall-check" \
  bash -c 'make -s -C "$0" help | tr "\n" " "' "$one"

: > "$STUB_LOG"
t "site-status with one site uses it" 0 "ManagedCluster: JOINED=True AVAILABLE=True" m "$one" site-status
t "  ... lists its hub Applications only" 0 "^ok$" bash -c 'out=$(PATH="$1:$PATH" make -s -C "$0" site-status 2>&1); grep -q rhoai-site-b-x <<<"$out" && ! grep -q rhoai-site-c-x <<<"$out" && echo ok' "$one" "$T/bin"
t "  ... reads the MaaS host and the site's models" 0 "smollm2-chat" m "$one" site-status
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
for target in site-check site-import site-join site-add uninstall-site; do
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
t "site-add passes ISSUER" 0 'add-site\.sh "\$n" letsencrypt' make -n -C "$one" site-add ISSUER=letsencrypt
t "tenant-user needs ORG" 2 "set ORG, such as: make tenant-user ORG=ORG_NAME" make -s -C "$one" tenant-user
t "tenant-call needs MODEL" 2 "set MODEL, such as: make tenant-call MODEL=MODEL_NAME" \
  make -s -C "$one" tenant-call TENANT_USER=u PASSWORD_FILE=p SUBSCRIPTION=s
t "tenant-call SITE= passes --site" 0 "--site site-c" make -n -C "$two" tenant-call TENANT_USER=u PASSWORD_FILE=p SUBSCRIPTION=s MODEL=m SITE=site-c
t "tenant-user uses the hub's login" 0 'kubeconfig "\.config/\$\(scripts/clusters\.sh --hub\)/kubeconfig"' \
  make -n -C "$one" tenant-user ORG=o TENANT_USER=u PASSWORD_FILE=p

echo "make-targets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
