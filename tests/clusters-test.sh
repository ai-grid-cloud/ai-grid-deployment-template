#!/usr/bin/env bash
# Tests for scripts/clusters.sh (clusters.yaml), with-cluster.sh,
# join-site.sh and import-site.sh's merged kubeconfig, against a stub oc.
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

repo() { # name, clusters.yaml body after the header -> a repository copy with that clusters.yaml
  local d="$T/$1"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\n%s\n' "$2" > "$d/clusters.yaml"; echo "$d"
}
site() { printf '  - {name: %s, role: %s, location: %s, api: "%s"}\n' "$@"; }

GOOD="hub: {name: hub, api: 'https://api.hub.example.com:6443'}
sites:
$(site site-b combined us-east https://api.site-b.example.com:6443)
$(site site-c inference us-west https://api.site-c.example.com:6443)"

d=$(repo good "$GOOD")
t "hub found" 0 "^hub$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && hub_name' "$d"
t "sites listed" 0 "^site-b site-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && echo $(site_names)' "$d"
t "a site's role" 0 "^inference$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_field site-c role' "$d"
t "kubeconfig path" 0 "/good/.config/site-b/kubeconfig$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_kubeconfig site-b' "$d"
t "unknown cluster" 1 "no cluster nope in" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_field nope role' "$d"
t "site_name with several sites asks for one" 1 "name a site: site-b, site-c" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name' "$d"
t "site_name keeps a given name" 0 "^site-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name site-c' "$d"
d1=$(repo one "hub: {name: hub, api: 'https://api.hub.example.com:6443'}
sites:
$(site site-b combined us-east https://api.site-b.example.com:6443)")
t "site_name defaults to the only site" 0 "^site-b$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name' "$d1"
t "clusters.sh --site prints the only site" 0 "^site-b$" bash "$d1/scripts/clusters.sh" --site
t "clusters.sh --site with several sites" 1 "name a site" bash "$d/scripts/clusters.sh" --site
t "site_name: the word site is the only site" 0 "^site-b$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name site' "$d1"

d=$(repo placeholder 'hub: {name: hub, api: REQUIRED-hubAPIURL}')
t "placeholder named" 1 "set these in clusters.yaml: REQUIRED-hubAPIURL" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo badrole "hub: {name: hub, api: 'https://h:6443'}
sites:
$(site s1 edge us https://s:6443)")
t "unknown role" 1 "site 1 role edge isn't combined, ingress or inference" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo hubrole "hub: {name: hub, api: 'https://h:6443'}
sites:
$(site s1 hub us https://s:6443)")
t "a site can't be a hub" 1 "site 1 role hub" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo twice "hub: {name: hub, api: 'https://h:6443'}
sites:
$(site hub combined us https://s:6443)")
t "a name used twice" 1 "the name hub is used twice" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo badname "hub: {name: hub, api: 'https://h:6443'}
sites:
$(site Site_B combined us https://s:6443)")
t "name not a DNS label" 1 "site 1 name Site_B isn't a DNS label" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo short "hub: {name: hub, api: 'https://h:6443'}
sites:
  - {name: s1, role: combined}")
t "a missing field" 1 "site 1 needs name, role, location and api" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo nohub 'sites: []')
t "no hub" 1 "hub needs name and api" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d="$T/broken"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"; printf 'apiVersion: v1\nkind: Clusters\nhub: [unclosed\n' > "$d/clusters.yaml"
t "invalid YAML" 1 "clusters.yaml isn't valid" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d="$T/none"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"
t "no clusters.yaml" 1 "copy clusters-example.yaml to clusters.yaml" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"

# A stub oc that logs its KUBECONFIG and arguments.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'EOF'
#!/bin/bash
echo "KUBECONFIG=$KUBECONFIG oc $*" >> "$STUB_LOG"
case "$*" in whoami*) [ -f "$STUB_DIR/fail-whoami" ] && exit 1; echo admin ;; login*) : > "$KUBECONFIG" ;; esac
exit 0
EOF
chmod +x "$T/bin/oc"; export STUB_LOG="$T/oc.log" STUB_DIR="$T"

d=$(repo run "$GOOD"); mkdir -p "$d/.config/hub" "$d/.config/site-b"; : > "$d/.config/hub/kubeconfig"
t "with-cluster sets KUBECONFIG" 0 "KUBECONFIG=$d/.config/hub/kubeconfig oc get nodes" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/with-cluster.sh" hub oc get nodes; cat "$STUB_LOG"' "$d" "$T/bin"
t "with-cluster without a login" 1 "no login for site-b: run make login NAME=site-b" \
  env PATH="$T/bin:$PATH" "$d/scripts/with-cluster.sh" site-b oc get nodes
touch "$T/fail-whoami"
t "with-cluster with an expired login" 1 "hub: login expired: run make login NAME=hub" \
  env PATH="$T/bin:$PATH" "$d/scripts/with-cluster.sh" hub oc get nodes
rm "$T/fail-whoami"; : > "$STUB_LOG"
: > "$STUB_LOG"; mkdir -p "$d/.config/site-c"; : > "$d/.config/site-c/kubeconfig"; rm -f "$d/.config/site-b/kubeconfig"
t "login with no name logs in only where needed" 0 "oc login --server https://api.site-b.example.com:6443 --web" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/login.sh" && cat "$STUB_LOG"' "$d" "$T/bin"
t "login skips working logins" 0 "hub: already logged in" bash -c 'PATH="$1:$PATH" "$0/scripts/login.sh"' "$d" "$T/bin"
t "login leaves a working hub login alone" 1 "^0$" grep -c "login --server https://api.hub" "$STUB_LOG"
: > "$STUB_LOG"
t "join-site labels from the file" 0 "oc label managedcluster site-c ai-grid/enabled=true ai-grid/role=inference location=us-west --overwrite" \
  bash -c 'PATH="$1:$PATH" JOIN_SITE_NO_WAIT=1 "$0/scripts/join-site.sh" site-c; cat "$STUB_LOG"' "$d" "$T/bin"
t "join-site with several sites needs a name" 1 "name a site: site-b, site-c" env PATH="$T/bin:$PATH" JOIN_SITE_NO_WAIT=1 "$d/scripts/join-site.sh"
mkdir -p "$d1/.config/hub" "$d1/.config/site-b"; : > "$d1/.config/hub/kubeconfig"; : > "$d1/.config/site-b/kubeconfig"; : > "$STUB_LOG"
t "join-site with one site needs no name" 0 "oc label managedcluster site-b ai-grid/enabled=true ai-grid/role=combined location=us-east" \
  bash -c 'PATH="$1:$PATH" JOIN_SITE_NO_WAIT=1 "$0/scripts/join-site.sh"; cat "$STUB_LOG"' "$d1" "$T/bin"
t "with-cluster site is the only site" 0 "KUBECONFIG=$d1/.config/site-b/kubeconfig oc get nodes" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/with-cluster.sh" site oc get nodes; cat "$STUB_LOG"' "$d1" "$T/bin"
t "with-cluster site with several sites" 1 "name a site: site-b, site-c" env PATH="$T/bin:$PATH" "$d/scripts/with-cluster.sh" site oc get nodes
: > "$STUB_LOG"
t "login NAME=site is the only site" 0 "oc login --server https://api.site-b.example.com:6443" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/login.sh" site; cat "$STUB_LOG"' "$d1" "$T/bin"
t "site check with several sites needs a name" 2 "name a site: site-b, site-c" env PATH="$T/bin:$PATH" "$d/scripts/check-prerequisites.sh" --step spoke
: > "$STUB_LOG"
t "site check with one site needs no name" 0 "KUBECONFIG=$d1/.config/site-b/kubeconfig oc whoami" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/check-prerequisites.sh" --step spoke; cat "$STUB_LOG"' "$d1" "$T/bin"
t "check-revisions without a hub login" 1 "no login for hub|login expired" env PATH="$T/bin:$PATH" LIBRARY=/nonexistent bash -c 'rm -f "$0/.config/hub/kubeconfig"; "$0/scripts/check-revisions.sh"' "$d"
: > "$d/.config/hub/kubeconfig"
t "join-site refuses the hub" 1 "hub is the hub" env PATH="$T/bin:$PATH" JOIN_SITE_NO_WAIT=1 "$d/scripts/join-site.sh" hub

# import-site.sh merges two kubeconfigs whose names collide (both "admin")
# into contexts hub and site, each keeping its own server and credentials.
kc() { # file server token
  cat > "$1" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: admin, cluster: {server: $2}}]
users: [{name: admin, user: {token: $3}}]
contexts: [{name: admin, context: {cluster: admin, user: admin}}]
current-context: admin
EOF
}
if command -v oc >/dev/null; then
  kc "$d/.config/hub/kubeconfig" https://api.hub.example.com:6443 hub-token
  kc "$d/.config/site-b/kubeconfig" https://api.site-b.example.com:6443 site-token
  m="$T/merged"
  t "merged kubeconfig: hub context" 0 "^https://api.hub.example.com:6443 hub-token$" bash -c '
    . "$0/scripts/clusters.sh"; clusters_load "$0"; merge_kubeconfigs hub site-b "$1"
    oc --kubeconfig "$1" config view --raw --context hub --minify -o jsonpath="{.clusters[0].cluster.server} {.users[0].user.token}"' "$d" "$m"
  t "merged kubeconfig: site context" 0 "^https://api.site-b.example.com:6443 site-token$" \
    oc --kubeconfig "$m" config view --raw --context site --minify -o jsonpath='{.clusters[0].cluster.server} {.users[0].user.token}'
fi

# console-call.sh signs in with the hub login's token: a stub oc answers the
# token and the Route, a stub curl logs its arguments and the header file.
mkdir -p "$T/cbin"; : > "$d/.config/hub/kubeconfig"
cat > "$T/cbin/oc" <<'STUB'
#!/bin/bash
case "$*" in whoami) echo admin ;; "whoami -t") [ -f "$STUB_DIR/no-token" ] && exit 1; echo sha256~FAKE_console_token ;; *"get route"*) echo console.apps.hub.example.com ;; esac
STUB
cat > "$T/cbin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.log"
out="" prev=""
for a in "$@"; do case "$a" in @*) cat "${a#@}" >> "$STUB_DIR/curl.log" ;; esac; [ "$prev" = -o ] && out=$a; prev=$a; done
echo '{"object":{"id":"org-1"}}' > "$out"; cat "$STUB_DIR/code" 2>/dev/null || printf 200
STUB
chmod +x "$T/cbin/oc" "$T/cbin/curl"; : > "$T/curl.log"
t "console-call calls the console's Route" 0 "HTTP 200" env PATH="$T/cbin:$PATH" "$d/scripts/console-call.sh" ai_grid.v1.Clusters/List
t "  ... with the hub login's token in a header file" 0 "Authorization: Bearer sha256~FAKE_console_token" cat "$T/curl.log"
t "  ... never on the command line" 1 "^0$" bash -c 'grep "^curl " "$0" | grep -c FAKE_console_token' "$T/curl.log"
t "  ... at the console's host and method" 0 "https://console.apps.hub.example.com/ai_grid.v1.Clusters/List" cat "$T/curl.log"
t "  ... prints only the reply on stdout when piped, for jq" 0 "^org-1$" \
  bash -c 'PATH="$0:$PATH" "$1/scripts/console-call.sh" ai_grid.v1.Tenants/Create 2>/dev/null | jq -r .object.id' "$T/cbin" "$d"
printf 403 > "$T/code"
t "  ... and fails on an error status" 1 "HTTP 403" env PATH="$T/cbin:$PATH" "$d/scripts/console-call.sh" ai_grid.v1.Tenants/Create
rm "$T/code"
touch "$T/no-token"
t "console-call without a token says how to get one" 1 "make login NAME=hub" env PATH="$T/cbin:$PATH" "$d/scripts/console-call.sh" ai_grid.v1.Clusters/List
rm "$T/no-token"

echo "clusters tests: $((total-fails)) ok, $fails failed"; exit "$fails"
