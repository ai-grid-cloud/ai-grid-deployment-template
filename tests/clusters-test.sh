#!/usr/bin/env bash
# Tests for scripts/clusters.sh (the clusters file), with-cluster.sh,
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

repo() { # name, clusters-file-body -> a repository copy with that clusters file
  local d="$T/$1"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"; printf '%s\n' "$2" > "$d/clusters"; echo "$d"
}

GOOD='# name role location api
hub      hub       -        https://api.hub.example.com:6443
site-b   combined  us-east  https://api.site-b.example.com:6443
site-c   inference us-west  https://api.site-c.example.com:6443'

d=$(repo good "$GOOD")
t "hub found" 0 "^hub$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && hub_name' "$d"
t "sites listed" 0 "^site-b site-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && echo $(site_names)' "$d"
t "a site's role" 0 "^inference$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_field site-c role' "$d"
t "kubeconfig path" 0 "/good/.config/site-b/kubeconfig$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_kubeconfig site-b' "$d"
t "unknown cluster" 1 "no cluster nope in" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_field nope role' "$d"

d=$(repo placeholder 'hub hub - REQUIRED-hubAPIURL')
t "placeholder named" 1 "REQUIRED-hubAPIURL" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo badrole 'hub hub - https://h:6443
s1 edge us https://s:6443')
t "unknown role" 1 "role edge" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo twohubs 'h1 hub - https://h:6443
h2 hub - https://g:6443')
t "two hubs" 1 "exactly one hub" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo badname 'hub hub - https://h:6443
Site_B combined us https://s:6443')
t "name not a DNS label" 1 "Site_B" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo short 'hub hub -')
t "missing column" 1 "4 columns" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"

# A stub oc that logs its KUBECONFIG and arguments.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'EOF'
#!/bin/bash
echo "KUBECONFIG=$KUBECONFIG oc $*" >> "$STUB_LOG"
case "$*" in whoami*) [ -f "$STUB_DIR/fail-whoami" ] && exit 1; echo admin ;; esac
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
t "join-site labels from the file" 0 "oc label managedcluster site-c ai-grid/enabled=true ai-grid/role=inference location=us-west --overwrite" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/join-site.sh" site-c; cat "$STUB_LOG"' "$d" "$T/bin"
t "check-revisions without a hub login" 1 "no login for hub|login expired" env PATH="$T/bin:$PATH" LIBRARY=/nonexistent bash -c 'rm -f "$0/.config/hub/kubeconfig"; "$0/scripts/check-revisions.sh"' "$d"
: > "$d/.config/hub/kubeconfig"
t "join-site refuses the hub" 1 "hub is the hub" env PATH="$T/bin:$PATH" "$d/scripts/join-site.sh" hub

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

echo "clusters tests: $((total-fails)) ok, $fails failed"; exit "$fails"
