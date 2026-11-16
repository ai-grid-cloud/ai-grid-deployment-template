#!/usr/bin/env bash
# Tests for scripts/check-revisions.sh with a stub oc answering the hub's
# Applications from $STUB_DIR/apps.json.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_grep [reject_grep]
  local name=$1 want=$2 expect=$3 reject=${4:-} rc out
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" "$D/scripts/check-revisions.sh" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; }; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
case " $* " in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io -n openshift-gitops "*) cat "$STUB_DIR/apps.json" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

D="$T/repo"; mkdir -p "$D/.config/hub"; cp -R "$SRC/scripts" "$SRC/root" "$D/"; : > "$D/.config/hub/kubeconfig"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"
. scripts/library.sh
PIN=$(library_pin "$SRC" libraryRevision) LIBURL=$(library_pin "$SRC" libraryRepoURL)
src() { printf '{"repoURL":"%s","targetRevision":"%s","path":"%s"}' "$1" "$2" "$3"; }
app1() { printf '{"metadata":{"name":"%s"},"spec":{"source":%s}}' "$1" "$2"; }
appn() { printf '{"metadata":{"name":"%s"},"spec":{"sources":[%s]}}' "$1" "$2"; }
apps() { local IFS=,; echo "{\"items\":[$*]}" > "$T/apps.json"; }

apps "$(app1 acm "$(src "$LIBURL" "$PIN" apps/acm/manifests)")" \
  "$(appn console "$(src https://github.com/ai-grid-cloud/ai-grid-provider-console.git 0c08 charts/x),$(src "${LIBURL%.git}" "$PIN" apps/console/manifests)")"
t "every library source at the pin: OK" 0 "^OK +acm .*$PIN" "^(OFF|HEAD) "
t "  ... other repositories aren't checked" 0 "^OK +console" "ai-grid-provider-console"

apps "$(app1 acm "$(src "$LIBURL" "$PIN" apps/acm/manifests)")" \
  "$(appn rhoai-site-b-1234 "$(src "$LIBURL" HEAD "")")" "$(app1 maas-db-local-cluster "$(src "$LIBURL" HEAD apps/maas-db/primary)")"
t "Applications the library's own ApplicationSets generate at HEAD: reported as the known limit, not a failure" 0 \
  "^HEAD +maas-db-local-cluster .*upstream-main-limits.md, L1" "^OFF "
t "  ... with a count" 0 "2 Application\(s\) read the library at HEAD"

owned() { # NAME SOURCE: an Application the root ApplicationSet apps generated
  printf '{"metadata":{"name":"%s","ownerReferences":[{"kind":"ApplicationSet","name":"apps"}]},"spec":{"source":%s}}' "$1" "$2"
}
ownedn() { printf '{"metadata":{"name":"%s","ownerReferences":[{"kind":"ApplicationSet","name":"apps"}]},"spec":{"sources":[%s]}}' "$1" "$2"; }
apps "$(owned acm "$(src "$LIBURL" HEAD apps/acm/manifests)")"
t "a root-generated Application at HEAD: OFF, exit 1 (the root pins its apps)" 1 "^OFF +acm .*HEAD" "^HEAD "
apps "$(ownedn grid-bootstrap "$(src "$LIBURL" "$PIN" ""),$(src "$LIBURL" HEAD apps/grid-bootstrap/policies)")"
t "  ... also when only one of its sources is at HEAD" 1 "^OFF +grid-bootstrap .*HEAD"
apps "$(owned acm "$(src "$LIBURL" "$PIN" apps/acm/manifests)")"
t "a root-generated Application at the pin: OK" 0 "^OK +acm"

apps "$(app1 acm "$(src "$LIBURL" 0123456789abcdef0123456789abcdef01234567 apps/acm/manifests)")"
t "a library source at another commit: OFF, exit 1" 1 "^OFF +acm .*0123456789ab"

rm "$D/.config/hub/kubeconfig"
t "no hub login: stops" 1 "no login for hub|login expired"

echo "check-revisions tests: $((total-fails)) ok, $fails failed"; exit "$fails"
