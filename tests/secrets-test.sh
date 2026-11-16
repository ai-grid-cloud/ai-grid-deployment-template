#!/usr/bin/env bash
# Tests for scripts/secrets.sh (make secrets), answering on stdin, with a stub podman.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SECRET='sha256~SECRET_do_not_print_4242'

mkdir -p "$T/bin"
cat > "$T/bin/podman" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/podman.log"
[ -z "${STUB_PODMAN_FAIL:-}" ] || exit 1
[ "$1 $2" = "login --authfile" ] && printf '{"auths":{"quay.io/rhoai":{"auth":"x"}}}\n' > "$3"
STUB
chmod +x "$T/bin/podman"

t() { # name condition...
  local name=$1; shift; total=$((total+1))
  if "$@"; then echo "   ok   $name"; else fails=$((fails+1)); echo "   FAIL $name; output:"; echo "$out"; fi
}
new_repo() {
  D="$T/repo-$total"; W="$T/stub-$total"; mkdir -p "$D" "$W"; : > "$W/podman.log"
  cp -R "$SRC/scripts" "$D/"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
}
run() { # ANSWERS [VAR=value...]: runs secrets.sh in $D with ANSWERS (one per line) on stdin
  local answers=$1; shift
  out=$(printf '%b' "$answers" | env PATH="$T/bin:$PATH" STUB_DIR="$W" "$@" "$D/scripts/secrets.sh" 2>&1) && rc=0 || rc=$?
}
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

new_repo
run "$SECRET-hub\n$SECRET-site\n$SECRET-deploy\n$SECRET-catalog\n"
t "asks for each: exit 0" [ "$rc" = 0 ]
t "  ... the hub's token" grep -qx "$SECRET-hub" "$D/.config/hub/token"
t "  ... the site's token" grep -qx "$SECRET-site" "$D/.config/site-b/token"
t "  ... the deployment token" grep -qx "$SECRET-deploy" "$D/.config/deployment-token"
t "  ... the catalog token" grep -qx "$SECRET-catalog" "$D/.config/catalog-token"
t "  ... files mode 600" [ "$(mode "$D/.config/hub/token")$(mode "$D/.config/catalog-token")$(mode "$D/.config/quay-auth.json")" = 600600600 ]
t "  ... .config and its cluster directories mode 700" [ "$(mode "$D/.config")$(mode "$D/.config/site-b")" = 700700 ]
t "  ... podman login for quay.io/rhoai, into .config/quay-auth.json" bash -c 'grep -qx "login --authfile $0/.config/quay-auth.json.new quay.io/rhoai" "$1/podman.log" && [ -s "$0/.config/quay-auth.json" ]' "$D" "$W"
t "  ... never prints a secret" bash -c '! grep -q SECRET_do_not_print <<<"$0"' "$out"
t "  ... never passes one to a command" bash -c '! grep -q SECRET_do_not_print "$0"' "$W/podman.log"
t "  ... says what's next" grep -q "make login NONINTERACTIVE=1" <<<"$out"

: > "$W/podman.log"
run "other\n"
t "rerun: existing files kept, nothing asked" bash -c '[ "$0" = 0 ] && grep -qx "$1-hub" "$2/.config/hub/token" && [ ! -s "$3/podman.log" ] && grep -q "exists, kept" <<<"$4"' "$rc" "$SECRET" "$D" "$W" "$out"

run "zero-hub\n" FORCE=0
t "FORCE=0 keeps the files" grep -qx "$SECRET-hub" "$D/.config/hub/token"

run "new-hub\n\n\n\n" FORCE=1
t "FORCE=1 replaces an answered one" grep -qx "new-hub" "$D/.config/hub/token"
t "  ... an empty answer skips it, keeping the old file" grep -qx "$SECRET-site" "$D/.config/site-b/token"
t "  ... and logs in to quay again" grep -q "login --authfile" "$W/podman.log"

new_repo
run "\n\n\n\n"
t "empty answers write nothing" bash -c '[ "$0" = 0 ] && [ ! -e "$1/.config/hub/token" ] && [ ! -e "$1/.config/catalog-token" ] && grep -q skipped <<<"$2"' "$rc" "$D" "$out"

new_repo
run "a\nb\nc\nd\n"; echo old > "$D/.config/quay-auth.json"
run "\n\n\n\n" FORCE=1 STUB_PODMAN_FAIL=1
t "podman login fails: exit 1 with the fix, the old login kept" bash -c '[ "$0" = 1 ] && grep -q "run make secrets again" <<<"$1" && grep -qx old "$2/.config/quay-auth.json"' "$rc" "$out" "$D"

new_repo; rm "$D/clusters.yaml"
run ""
t "no clusters.yaml: stops" bash -c '[ "$0" = 1 ] && grep -q "no clusters.yaml" <<<"$1"' "$rc" "$out"

echo "secrets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
