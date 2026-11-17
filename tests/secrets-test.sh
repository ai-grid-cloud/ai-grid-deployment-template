#!/usr/bin/env bash
# Tests for scripts/secrets.sh (make secrets), answering on stdin. Every
# command it may run is a stub that logs its arguments, so the tests can check
# that no secret reaches a command line.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
S='SECRET_do_not_print_4242'
LOG="$T/argv.log"; : > "$LOG"

# Logging wrappers around the real commands (podman and oc must not run at all).
mkdir -p "$T/bin"
for cmd in kubectl jq awk sed cp mv chmod mkdir mktemp rm cat stat grep tr head sort; do
  real=$(command -v "$cmd")
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s"\nexec "%s" "$@"\n' "$cmd" "$LOG" "$real" > "$T/bin/$cmd"
done
for cmd in podman oc; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s"\nexit 1\n' "$cmd" "$LOG" > "$T/bin/$cmd"
done
chmod +x "$T/bin/"*

t() { # name condition...
  local name=$1; shift; total=$((total+1))
  if "$@"; then echo "   ok   $name"; else fails=$((fails+1)); echo "   FAIL $name; output:"; echo "$out"; fi
}
BASE='apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
# The hub (a user comment).
hub: {api: "https://api.hub.example.com:6443"}
sites:
  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}
  # another user comment
repositories:
  catalog: "https://github.com/o/c.git"
options:
  # GATE_INTERVAL: 15
  KEYCLOAK: install'
new_repo() { # [BODY]: a repository with BODY (default BASE) as .config/clusters.yaml
  D="$T/repo-$total"; mkdir -p "$D/.config"; chmod 700 "$D/.config"
  cp -R "$SRC/scripts" "$D/"
  printf '%s\n' "${1:-$BASE}" > "$D/.config/clusters.yaml"; chmod 600 "$D/.config/clusters.yaml"
}
ENVV=()
run() { # ANSWER...: runs secrets.sh in $D, one answer per line on stdin, with ENVV set
  out=$(printf '%s\n' "$@" | env PATH="$T/bin:$PATH" "${ENVV[@]}" "$D/scripts/secrets.sh" 2>&1) && rc=0 || rc=$?
}
get() { # JQ_PATH: the value secret_get reads back from $D
  bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" >/dev/null && secret_get "$1"' "$D" "$1"
}
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
public_part() { # the file without the secret block, trailing blank lines dropped
  sed '/^# Secrets (make secrets writes this part/,$d' "$D/.config/clusters.yaml" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
no_leak() { ! grep -q "$S" <<<"$out" && ! grep -q "$S" "$LOG"; }

# 1. Every answer, the hub by token and the site by username and password.
new_repo
run "$S-hub" "" "kubeadmin" "$S-pw" "$S-deploy" "$S-catalog" "robot+ci" "$S-quay"
t "asks for each: exit 0" [ "$rc" = 0 ]
t "  ... the hub's token" [ "$(get '.credentials.hub.token')" = "$S-hub" ]
t "  ... the site's username" [ "$(get '.credentials["site-b"].username')" = kubeadmin ]
t "  ... the site's password, through cluster_secret" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && [ "$(cluster_secret site-b password)" = "$1-pw" ]' "$D" "$S"
t "  ... the deployment token" [ "$(get .github.deploymentToken)" = "$S-deploy" ]
t "  ... the catalog token" [ "$(get .github.catalogToken)" = "$S-catalog" ]
t "  ... the quay username" [ "$(get .quay.username)" = "robot+ci" ]
t "  ... the quay password" [ "$(get .quay.password)" = "$S-quay" ]
t "  ... the rest of the file unchanged" [ "$(public_part)" = "$BASE" ]
t "  ... file mode 600, .config mode 700" [ "$(mode "$D/.config/clusters.yaml")$(mode "$D/.config")" = 600700 ]
t "  ... no temporary files left" [ "$(ls -A "$D/.config")" = clusters.yaml ]
t "  ... never prints a secret or passes one to a command" no_leak
t "  ... never runs podman or oc" bash -c '! grep -qE "^(podman|oc) " "$0"' "$LOG"
t "  ... says what's next" grep -q "Next: make login, then make prereqs." <<<"$out"
first=$(cat "$D/.config/clusters.yaml")

# 2. A rerun keeps everything and asks nothing; FORCE=0 is not FORCE.
run "other" "other" "other" "other" "other" "other" "other" "other"
t "rerun: exit 0, file unchanged" bash -c '[ "$0" = 0 ] && [ "$(cat "$1/.config/clusters.yaml")" = "$2" ]' "$rc" "$D" "$first"
t "  ... says kept" grep -q "kept" <<<"$out"
ENVV=(FORCE=0); run "other" "other" "other" "other" "other" "other" "other" "other"; ENVV=()
t "FORCE=0 keeps the values" [ "$(get '.credentials.hub.token')" = "$S-hub" ]

# 3. FORCE=1 asks again: an answer replaces, an empty answer keeps.
ENVV=(FORCE=1); run "$S-newhub" "$S-sitetoken" "" "" "" "" ""; ENVV=()
t "FORCE=1: exit 0" [ "$rc" = 0 ]
t "  ... replaces the hub's token" [ "$(get '.credentials.hub.token')" = "$S-newhub" ]
t "  ... a token replaces the site's username and password" bash -c '[ "$0" = "$1-sitetoken" ] && [ -z "$2" ]' \
  "$(get '.credentials["site-b"].token')" "$S" "$(get '.credentials["site-b"].password')"
t "  ... an empty answer keeps the old value" [ "$(get .github.catalogToken)" = "$S-catalog" ]
t "  ... the rest of the file still unchanged" [ "$(public_part)" = "$BASE" ]
t "  ... one secret block" [ "$(grep -c '^credentials:' "$D/.config/clusters.yaml")$(grep -c '^# Secrets (make secrets' "$D/.config/clusters.yaml")" = 11 ]
t "  ... no leak" no_leak

# 4. Empty answers skip everything.
new_repo
run "" "" "" "" "" "" ""
t "empty answers: exit 0, nothing set" bash -c '[ "$0" = 0 ] && [ -z "$1$2$3" ]' "$rc" "$(get .credentials.hub.token)" "$(get .github.catalogToken)" "$(get .quay.username)"
t "  ... says skipped" grep -q skipped <<<"$out"
t "  ... the rest of the file unchanged" [ "$(public_part)" = "$BASE" ]

# 5. A password with quotes, backslashes, spaces and a tab round-trips; a
#    token's surrounding whitespace is trimmed.
new_repo
pw=" $S \"q\" back\\slash \\n tab	end "
run "  $S-hub  " "" " admin " "$pw" "" "" "" ""
t "odd password: exit 0" [ "$rc" = 0 ]
t "  ... round-trips exactly" [ "$(get '.credentials["site-b"].password')" = "$pw" ]
t "  ... the token is trimmed" [ "$(get .credentials.hub.token)" = "$S-hub" ]
t "  ... the username is trimmed" [ "$(get '.credentials["site-b"].username')" = admin ]
t "  ... no leak" no_leak

# 6. Existing secrets in the user's own layout, with a kubeconfig cluster and a
#    comment after the block; a kubeconfig is kept even with FORCE=1.
body="$BASE
credentials:
  # the hub uses a kubeconfig
  hub: {kubeconfig: .config/k}
  site-b:
    username: u
    password: p
github: {catalogToken: $S-cat}
# A comment that belongs to quay
quay:
  username: r"
new_repo "$body"
run "$S-deploy" "$S-quay"
t "existing block: exit 0" [ "$rc" = 0 ]
t "  ... kubeconfig kept" [ "$(get .credentials.hub.kubeconfig)" = .config/k ]
t "  ... username and password kept" [ "$(get '.credentials["site-b"].username')$(get '.credentials["site-b"].password')" = up ]
t "  ... only the missing ones asked" bash -c '[ "$0" = "$1-cat" ] && [ "$2" = "$1-deploy" ] && [ "$3" = r ] && [ "$4" = "$1-quay" ]' \
  "$(get .github.catalogToken)" "$S" "$(get .github.deploymentToken)" "$(get .quay.username)" "$(get .quay.password)"
t "  ... the rest of the file unchanged" [ "$(public_part)" = "$BASE" ]
ENVV=(FORCE=1); run "" "" "" "" "" "" ""; ENVV=()
t "FORCE=1 keeps a kubeconfig without asking" bash -c '[ "$0" = 0 ] && [ "$1" = .config/k ]' "$rc" "$(get .credentials.hub.kubeconfig)"

# 7. Secrets in the middle of the file: the keys after them stay.
new_repo "apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
github:
  catalogToken: c
# Settings below
hub: {api: \"https://api.hub.example.com:6443\"}
repositories: {catalog: \"https://github.com/o/c.git\"}
sites: []"
run "" "" "" "" "" ""
t "a block in the middle: exit 0" [ "$rc" = 0 ]
t "  ... the keys after it, with their comment, stay" [ "$(public_part)" = "apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
# Settings below
hub: {api: \"https://api.hub.example.com:6443\"}
repositories: {catalog: \"https://github.com/o/c.git\"}
sites: []" ]
t "  ... the value kept" [ "$(get .github.catalogToken)" = c ]

# 8. Only ./clusters.yaml: copied to .config/clusters.yaml.
D="$T/repo-root"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"; printf '%s\n' "$BASE" > "$D/clusters.yaml"
run "$S-hub" "" "" "" "" "" ""
t "only ./clusters.yaml: exit 0" [ "$rc" = 0 ]
t "  ... copied to .config/clusters.yaml" bash -c '[ "$(head -n 12 "$0/.config/clusters.yaml")" = "$1" ]' "$D" "$BASE"
t "  ... the committed file untouched" [ "$(cat "$D/clusters.yaml")" = "$BASE" ]
t "  ... says the scripts now read it" grep -q "scripts read .config/clusters.yaml" <<<"$out"
t "  ... mode 600, .config 700" [ "$(mode "$D/.config/clusters.yaml")$(mode "$D/.config")" = 600700 ]
t "  ... the token written" [ "$(get .credentials.hub.token)" = "$S-hub" ]

# 9. A file that doesn't load stops before asking.
new_repo "$BASE
bogus: 1"
before=$(cat "$D/.config/clusters.yaml")
run "$S-hub" "" "" "" "" "" ""
t "an invalid file: exit 1, file kept" bash -c '[ "$0" = 1 ] && [ "$(cat "$1/.config/clusters.yaml")" = "$2" ] && grep -q "unknown keys" <<<"$3"' "$rc" "$D" "$before" "$out"

new_repo "$BASE
github: {catalogToken: \"two\\nlines\"}"
before=$(cat "$D/.config/clusters.yaml")
run "" "" "" "" "" "" ""
t "a stored value spans lines: exit 1, file kept" bash -c '[ "$0" = 1 ] && [ "$(cat "$1/.config/clusters.yaml")" = "$2" ] && grep -q "github.catalogToken: a value can.t span lines" <<<"$3" && [ "$(ls -A "$1/.config")" = clusters.yaml ]' "$rc" "$D" "$before" "$out"

# 11. NAME: asks only for that one and replaces it, whatever is stored.
new_repo "$body"
out=$(printf '%s\n' "$S-newhub" | env PATH="$T/bin:$PATH" "$D/scripts/secrets.sh" hub 2>&1) && rc=0 || rc=$?
t "NAME=hub: exit 0" [ "$rc" = 0 ]
t "  ... replaces the kubeconfig with the token" bash -c '[ "$0" = "$1-newhub" ] && [ -z "$2" ]' "$(get .credentials.hub.token)" "$S" "$(get .credentials.hub.kubeconfig)"
t "  ... leaves everything else" bash -c '[ "$0" = up ] && [ "$1" = "$2-cat" ] && [ "$3" = r ]' \
  "$(get '.credentials["site-b"].username')$(get '.credentials["site-b"].password')" "$(get .github.catalogToken)" "$S" "$(get .quay.username)"
t "  ... asks nothing else" bash -c '! grep -qE "^(github|quay)|site-b" <<<"$0"' "$out"
t "  ... no leak" no_leak
out=$(printf '%s\n' "" "admin2" "$S-pw2" | env PATH="$T/bin:$PATH" "$D/scripts/secrets.sh" site-b 2>&1) && rc=0 || rc=$?
t "NAME=site-b: username and password replace the stored ones" bash -c '[ "$0" = 0 ] && [ "$1" = admin2 ] && [ "$2" = "$3-pw2" ]' \
  "$rc" "$(get '.credentials["site-b"].username')" "$(get '.credentials["site-b"].password')" "$S"
t "  ... the hub kept" [ "$(get .credentials.hub.token)" = "$S-newhub" ]
out=$(printf '%s\n' "$S-d2" "$S-c2" | env PATH="$T/bin:$PATH" "$D/scripts/secrets.sh" github 2>&1) && rc=0 || rc=$?
t "NAME=github: both tokens replaced" bash -c '[ "$0" = 0 ] && [ "$1" = "$3-d2" ] && [ "$2" = "$3-c2" ]' "$rc" "$(get .github.deploymentToken)" "$(get .github.catalogToken)" "$S"
t "  ... quay kept" [ "$(get .quay.username)" = r ]
out=$(printf '%s\n' "robot2" "$S-q2" | env PATH="$T/bin:$PATH" "$D/scripts/secrets.sh" quay 2>&1) && rc=0 || rc=$?
t "NAME=quay: the robot account replaced" bash -c '[ "$0" = 0 ] && [ "$1" = robot2 ] && [ "$2" = "$3-q2" ]' "$rc" "$(get .quay.username)" "$(get .quay.password)" "$S"
t "  ... github kept" [ "$(get .github.catalogToken)" = "$S-c2" ]
t "  ... the rest of the file unchanged" [ "$(public_part)" = "$BASE" ]
t "  ... no leak" no_leak
before=$(cat "$D/.config/clusters.yaml")
out=$(printf '\n' | env PATH="$T/bin:$PATH" "$D/scripts/secrets.sh" nope 2>&1) && rc=0 || rc=$?
t "an unknown NAME: exit 1 with the valid names, file kept" bash -c '[ "$0" = 1 ] && grep -q "NAME=nope isn.t one of: hub site-b github quay" <<<"$1" && [ "$(cat "$2/.config/clusters.yaml")" = "$3" ]' "$rc" "$out" "$D" "$before"
t "make secrets NAME= passes the name" bash -c 'make -n -C "$0" secrets NAME=site-b | grep -q "scripts/secrets.sh site-b"' "$SRC"

# M9: with FORCE=1, an empty answer keeps the stored value and says so.
new_repo
run "$S-hub" "" "kubeadmin" "$S-pw" "$S-d" "$S-c" "robot" "$S-q"

ENVV=(FORCE=1); run "" "" "" "" "" "" "" "" "" ""; ENVV=()
t "FORCE=1 and an empty answer: kept, not skipped" bash -c '! grep -q skipped <<<"$0" && grep -q "credentials.hub: kept" <<<"$0" && grep -q "github.catalogToken: kept" <<<"$0"' "$out"

# 10. No clusters.yaml at all.
D="$T/repo-none"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"; cp "$SRC/clusters-example.yaml" "$D/"
run ""
t "no clusters.yaml: creates .config/clusters.yaml from the example and stops, exit 0" bash -c '[ "$0" = 0 ] && grep -q "edit it, then run make secrets again" <<<"$1" && cmp -s "$2/clusters-example.yaml" "$2/.config/clusters.yaml"' "$rc" "$out" "$D"
t "  ... file 600, directory 700" bash -c '[ "$(stat -f %Lp "$0/.config/clusters.yaml" 2>/dev/null || stat -c %a "$0/.config/clusters.yaml")$(stat -f %Lp "$0/.config" 2>/dev/null || stat -c %a "$0/.config")" = 600700 ]' "$D"

# make config: only creates the private file from the example, never overwrites it.
D="$T/config"; mkdir -p "$D"; cp -R "$SRC/scripts" "$SRC/Makefile" "$SRC/clusters-example.yaml" "$D/"
out=$(make -s -C "$D" config 2>&1) && rc=0 || rc=$?
t "make config: creates .config/clusters.yaml from the example" bash -c '[ "$0" = 0 ] && grep -q "Created .config/clusters.yaml.*edit it" <<<"$1" && cmp -s "$2/clusters-example.yaml" "$2/.config/clusters.yaml"' "$rc" "$out" "$D"
t "  ... .config mode 700, the file mode 600" bash -c '[ "$(stat -f %Lp "$0/.config" 2>/dev/null || stat -c %a "$0/.config")$(stat -f %Lp "$0/.config/clusters.yaml" 2>/dev/null || stat -c %a "$0/.config/clusters.yaml")" = 700600 ]' "$D"
D2="$T/config-root"; mkdir -p "$D2"; cp -R "$SRC/scripts" "$SRC/Makefile" "$SRC/clusters-example.yaml" "$D2/"; echo "# ours" > "$D2/clusters.yaml"
out=$(make -s -C "$D2" config 2>&1) && rc=0 || rc=$?
t "make config with a clusters.yaml: copies that one, as make secrets does" bash -c '[ "$0" = 0 ] && grep -q "Copied clusters.yaml" <<<"$1" && cmp -s "$2/clusters.yaml" "$2/.config/clusters.yaml"' "$rc" "$out" "$D2"
echo "mine" >> "$D/.config/clusters.yaml"
out=$(make -s -C "$D" config 2>&1) && rc=0 || rc=$?
t "make config again: refuses, the file kept" bash -c '[ "$0" != 0 ] && grep -q "already exists" <<<"$1" && tail -n1 "$2/.config/clusters.yaml" | grep -qx mine' "$rc" "$out" "$D"
echo "secrets tests: $((total-fails)) ok, $fails failed"; exit "$fails"
