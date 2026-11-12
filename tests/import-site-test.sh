#!/usr/bin/env bash
# Tests for scripts/import-site.sh's one-command flow, with a stub oc and a stub
# library import script that prints its arguments.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
REAL_OC=$(command -v oc)

t() { # name want_rc expect_grep reject_grep input [args...]: runs import-site.sh with stdin from input
  local name=$1 want=$2 expect=$3 reject=$4 input=$5; shift 5; local rc out
  total=$((total+1))
  out=$(printf '%s' "$input" | env PATH="$T/bin:$PATH" LIBRARY="$T/lib" IMPORT_SITE_PROMPT="${PROMPT:-}" \
    "$D/scripts/import-site.sh" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; }; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The stub library import script: a summary, then whether it would import.
mkdir -p "$T/lib/docs/acm/cluster-onboarding" "$T/bin"
cat > "$T/lib/docs/acm/cluster-onboarding/import-managed-cluster.sh" <<'LIB'
echo "summary for $*"
case " $* " in *" --yes "*) echo "IMPORTED" ;; *) echo "No changes were made. Rerun with --yes to import the cluster." ;; esac
LIB
git -c init.defaultBranch=main -C "$T/lib" init -q && git -C "$T/lib" add -A &&
  git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com -C "$T/lib" commit -qm lib
# The stub oc: logins work; config goes to the real oc (merge_kubeconfigs).
cat > "$T/bin/oc" <<STUB
#!/bin/bash
case "\$1" in whoami) echo admin ;; config) exec "$REAL_OC" "\$@" ;; *) echo "stub oc: \$*" >&2; exit 2 ;; esac
STUB
chmod +x "$T/bin/oc"

D="$T/repo"; mkdir -p "$D/root"; cp -R "$SRC/scripts" "$D/"
printf '  libraryRevision: %s\n' "$(git -C "$T/lib" rev-parse HEAD)" > "$D/root/kustomization.yaml"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
for n in hub site-b; do
  mkdir -p "$D/.config/$n"
  printf 'apiVersion: v1\nkind: Config\nclusters: [{name: c, cluster: {server: "https://api.%s.example.com:6443"}}]\nusers: [{name: u, user: {token: x}}]\ncontexts: [{name: x, context: {cluster: c, user: u}}]\ncurrent-context: x\n' "$n" > "$D/.config/$n/kubeconfig"
done

t "no TTY: previews only" 0 "Rerun with --yes" "IMPORTED|Import site-b now" ""
t "no name: the only site" 0 "summary for --hub-context hub --spoke-context site --cluster-name site-b" "" ""
PROMPT=1 t "prompt: y imports" 0 "Import site-b now\? \[y/N\].*IMPORTED|IMPORTED" "" $'y\n'
PROMPT=1 t "prompt: y runs the import with --yes" 0 "summary for .*--cluster-name site-b --yes" "" $'y\n'
PROMPT=1 t "prompt: anything else doesn't import" 0 "Not imported" "IMPORTED" $'n\n'
PROMPT=1 t "prompt: no answer doesn't import" 0 "Not imported" "IMPORTED" ""
t "--yes skips the prompt" 0 "IMPORTED" "Import site-b now" "" --yes
t "a name and --yes" 0 "--cluster-name site-b --yes" "Import site-b now" "" site-b --yes

echo "import-site tests: $((total-fails)) ok, $fails failed"; exit "$fails"
