#!/usr/bin/env bash
# Tests for scripts/join-site.sh's wait: a deployment repository with a local
# origin, and a stub oc that reports deployment-root's sync from a file.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }

t() { # name want_rc expect_grep [reject_grep]
  local name=$1 want=$2 expect=$3 reject=${4:-} rc out
  total=$((total+1)); : > "$T/oc.log"
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" JOIN_WAIT_SECONDS=2 JOIN_WAIT_INTERVAL=1 "$D/scripts/join-site.sh" 2>&1) && rc=0 || rc=$?
  out+=$'\n'$(cat "$T/oc.log")
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && { [ -z "$reject" ] || ! grep -qE -- "$reject" <<<"$out"; }; then
    echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
echo "oc $*" >> "$STUB_DIR/oc.log"
case " $* " in
  *" whoami "*) echo admin ;;
  *" get applications.argoproj.io deployment-root "*) cat "$STUB_DIR/root-sync" 2>/dev/null ;;
  *" get managedcluster "*) [ -f "$STUB_DIR/mc.json" ] || exit 1; cat "$STUB_DIR/mc.json" ;;
  *" label "*) echo "managedcluster labeled" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

g init -q --bare "$T/origin.git"
D="$T/repo"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
printf '.config/\n' > "$D/.gitignore"
for n in hub site-b; do mkdir -p "$D/.config/$n"; : > "$D/.config/$n/kubeconfig"; done
g -C "$D" init -q && g -C "$D" add -A && g -C "$D" commit -qm one && g -C "$D" remote add origin "$T/origin.git" && g -C "$D" push -q origin HEAD:main
head=$(g -C "$D" rev-parse HEAD)

echo "Synced $head" > "$T/root-sync"
t "synced: labels the site" 0 "oc label managedcluster site-b ai-grid/enabled=true" "Waiting"
echo "Synced 0000000000000000000000000000000000000000" > "$T/root-sync"
t "not synced yet: waits, then times out without labelling" 1 "hasn't synced ${head:0:7}" " label "
t "  ... with a progress line" 1 "Waiting for the hub to sync ${head:0:7}"
echo change > "$D/file"; g -C "$D" add file; g -C "$D" commit -qm two
t "unpushed commits: asks to push first" 1 "1 commit\(s\) not pushed yet; push first" " label "

echo '{"metadata":{"labels":{"ai-grid/enabled":"true","ai-grid/role":"combined","location":"us-east"}}}' > "$T/mc.json"
t "labels already set: says so, no wait, no label" 0 "site-b: labels already set" "Waiting| label |push first"
echo '{"metadata":{"labels":{"ai-grid/enabled":"true","ai-grid/role":"inference","location":"us-east"}}}' > "$T/mc.json"
t "a different role: still checks the push" 1 "push first"
rm "$T/mc.json"

echo "join-site tests: $((total-fails)) ok, $fails failed"; exit "$fails"
