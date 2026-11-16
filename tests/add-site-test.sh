#!/usr/bin/env bash
# Tests for scripts/add-site.sh. On upstream main a site needs no files in the
# deployment repository: the library reads no per-site values from it, so the
# publicly trusted MaaS certificate can't be attached (docs/upstream-main-limits.md,
# L4 and L5). add-site.sh says so, writes nothing and reads no cluster.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

t() { # name want_rc expect_grep [args...]: runs add-site.sh in $D with an oc that fails if called
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$(env PATH="$T/bin:$PATH" "$D/scripts/add-site.sh" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
check() { total=$((total+1)); if "${@:2}"; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1"; fi; }

mkdir -p "$T/bin"
printf '#!/bin/bash\necho "stub oc: unexpected: $*" >&2; exit 2\n' > "$T/bin/oc"; chmod +x "$T/bin/oc"

repo() { # name sites-yaml -> a deployment copy
  local d="$T/$1"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n%s\n' "$2" > "$d/clusters.yaml"
  echo "$d"
}
B='  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}'
I='  - {name: site-i, role: inference, location: us-west, api: "https://api.site-i.example.com:6443"}'

D=$(repo one "$B")
t "combined site: nothing to write, and why" 0 "upstream-main-limits.md" site-b
check "  ... writes no file" eval '[ -z "$(cd "$D" && ls -d apps sites values 2>/dev/null)" ]'
t "the only site by default" 0 "site-b \(combined\): no files to write"
t "an issuer argument is accepted and unused" 0 "no files to write" site-b letsencrypt
D=$(repo two "$B
$I")
t "inference site: nothing needed" 0 "site-i is an inference site: it needs no MaaS files" site-i
t "unknown site: stops" 1 "nope" nope
t "too many arguments: usage" 2 "usage" a b c

echo "add-site tests: $((total-fails)) ok, $fails failed"; exit "$fails"
