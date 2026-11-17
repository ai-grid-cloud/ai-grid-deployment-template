#!/usr/bin/env bash
# Tests for scripts/clusters.sh (clusters.yaml), with-cluster.sh and
# import-site.sh's merged kubeconfig, against a stub oc.
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
site() { printf '  - {name: %s, api: "%s"}\n' "$@"; }

GOOD="hub: {api: 'https://api.hub.example.com:6443'}
sites:
$(site site-b https://api.site-b.example.com:6443)
$(site site-c https://api.site-c.example.com:6443)"

d=$(repo good "$GOOD")
t "hub found" 0 "^hub$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && hub_name' "$d"
t "sites listed" 0 "^site-b site-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && echo $(site_names)' "$d"
t "rows: name, kind and api" 0 "^hub hub https://api.hub.example.com:6443 site-b site https://api.site-b.example.com:6443 site-c site https://api.site-c.example.com:6443$" \
  bash -c 'echo $(bash "$0/scripts/clusters.sh" --rows "$0")' "$d"
t "cluster_api: a site's" 0 "^https://api.site-c.example.com:6443$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_api site-c' "$d"
t "cluster_api: the hub's" 0 "^https://api.hub.example.com:6443$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_api hub' "$d"
t "kubeconfig path" 0 "/good/.config/site-b/kubeconfig$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_kubeconfig site-b' "$d"
t "cluster_api: an unknown cluster" 1 "no cluster nope in" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_api nope' "$d"
t "cluster_kubeconfig: an unknown cluster" 1 "no cluster nope in" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_kubeconfig nope' "$d"
t "site_name with several sites asks for one" 1 "name a site: site-b, site-c" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name' "$d"
t "site_name keeps a given name" 0 "^site-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name site-c' "$d"
d1=$(repo one "hub: {api: 'https://api.hub.example.com:6443'}
sites:
$(site site-b https://api.site-b.example.com:6443)")
t "site_name defaults to the only site" 0 "^site-b$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name' "$d1"
t "clusters.sh --site prints the only site" 0 "^site-b$" bash "$d1/scripts/clusters.sh" --site
t "clusters.sh --site with several sites" 1 "name a site" bash "$d/scripts/clusters.sh" --site
t "site_name: the word site is no longer special" 1 "site isn't a site in clusters.yaml: site-b" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name site' "$d1"
t "site_name refuses a name that isn't a site" 1 "hub isn't a site in clusters.yaml: site-b, site-c" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && site_name hub' "$d"
t "clusters.sh --hub prints the hub" 0 "^hub$" bash "$d1/scripts/clusters.sh" --hub

d=$(repo placeholder 'hub: {api: REQUIRED-hubAPIURL}')
t "placeholder named" 1 "set these in clusters.yaml: REQUIRED-hubAPIURL" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo twice "hub: {api: 'https://h:6443'}
sites:
$(site hub https://s:6443)")
t "a site named hub" 1 "the name hub is used twice" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo twice2 "hub: {api: 'https://h:6443'}
sites:
$(site s1 https://s:6443)
$(site s1 https://t:6443)")
t "two sites with one name" 1 "the name s1 is used twice" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo badname "hub: {api: 'https://h:6443'}
sites:
$(site Site_B https://s:6443)")
t "name not a DNS label" 1 "site 1 name Site_B isn't a DNS label" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo short "hub: {api: 'https://h:6443'}
sites:
  - {name: s1}")
t "a site without an api" 1 "site 1 needs name and api" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo noname "hub: {api: 'https://h:6443'}
sites:
  - {api: 'https://s:6443'}")
t "a site without a name" 1 "site 1 needs name and api" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo http "hub: {api: 'https://h:6443'}
sites:
$(site s1 http://s:6443)")
t "an api that isn't https" 1 "site 1 api http://s:6443 isn't an https URL" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d=$(repo nohub 'sites: []')
t "no hub" 1 "hub needs api" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d="$T/broken"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"; printf 'apiVersion: v1\nkind: Clusters\nhub: [unclosed\n' > "$d/clusters.yaml"
t "invalid YAML" 1 "clusters.yaml isn't valid" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"
d="$T/none"; mkdir -p "$d"; cp -R "$SRC/scripts" "$d/"
t "no clusters.yaml" 1 "copy clusters-example.yaml to .config/clusters.yaml" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0"' "$d"

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
mkdir -p "$d1/.config/hub" "$d1/.config/site-b"; : > "$d1/.config/hub/kubeconfig"; : > "$d1/.config/site-b/kubeconfig"; : > "$STUB_LOG"
t "with-cluster takes a site's name" 0 "KUBECONFIG=$d1/.config/site-b/kubeconfig oc get nodes" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/with-cluster.sh" site-b oc get nodes; cat "$STUB_LOG"' "$d1" "$T/bin"
t "with-cluster has no word site" 1 "no cluster site in" env PATH="$T/bin:$PATH" "$d1/scripts/with-cluster.sh" site oc get nodes
t "site check with several sites needs a name" 2 "name a site: site-b, site-c" env PATH="$T/bin:$PATH" "$d/scripts/check-prerequisites.sh" --step spoke
: > "$STUB_LOG"
t "site check with one site needs no name" 0 "KUBECONFIG=$d1/.config/site-b/kubeconfig oc whoami" \
  bash -c 'PATH="$1:$PATH" "$0/scripts/check-prerequisites.sh" --step spoke; cat "$STUB_LOG"' "$d1" "$T/bin"
t "check-revisions without a hub login" 1 "no login for hub|login expired" env PATH="$T/bin:$PATH" LIBRARY=/nonexistent bash -c 'rm -f "$0/.config/hub/kubeconfig"; "$0/scripts/check-revisions.sh"' "$d"
: > "$d/.config/hub/kubeconfig"

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

# Install settings in clusters.yaml (catalog.url, options:).
d=$(repo settings "hub: {api: 'https://h:6443'}
sites:
  - {name: site-b, api: 'https://s:6443'}
catalog: {url: 'https://github.com/acme/catalog.git'}
options: {LIBRARY: deployment-template, GATE_ROOT_SECONDS: 900, ALLOW_GENERIC_LOGIN: true, KEYCLOAK: install, PROVIDER_ADMIN_TOKEN_DURATION: ''}")
t "the hub is always named hub" 0 "^hub$" bash "$d/scripts/clusters.sh" --hub
t "settings: the catalog" 0 "^CATALOG_REPO_URL=https://github.com/acme/catalog.git$" bash "$d/scripts/clusters.sh" --settings "$d"
t "settings: the library" 0 "^LIBRARY_REVISION=deployment-template$" bash "$d/scripts/clusters.sh" --settings "$d"
t "an issuer: on a site is an unknown key" 1 "sites\[s1\].issuer" bash "$(repo siteissuer "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', issuer: x}")/scripts/clusters.sh" --hub
t "settings: a number" 0 "^GATE_ROOT_SECONDS=900$" bash "$d/scripts/clusters.sh" --settings "$d"
t "settings: true is 1" 0 "^ALLOW_GENERIC_LOGIN=1$" bash "$d/scripts/clusters.sh" --settings "$d"
t "settings: an empty value is kept" 0 "^PROVIDER_ADMIN_TOKEN_DURATION=$" bash "$d/scripts/clusters.sh" --settings "$d"
d=$(repo nosettings "hub: {api: 'https://h:6443'}")
t "settings: none when the file sets none" 0 "^$" bash "$d/scripts/clusters.sh" --settings "$d"
d=$(repo catalogplaceholder "$GOOD
catalog: {url: REQUIRED-catalogRepoURL}")
t "catalog placeholder: the file still loads" 0 "^site-b site" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... and counts as no catalog" 0 "^CATALOG_REPO_URL=$" bash "$d/scripts/clusters.sh" --settings "$d"
d2=$(repo privcatalog "$GOOD"); mkdir -p "$d2/.config"; chmod 700 "$d2/.config"
{ cat "$d2/clusters.yaml"; echo "catalog: {url: REQUIRED-catalogRepoURL}"; } > "$d2/.config/clusters.yaml"; rm "$d2/clusters.yaml"; chmod 600 "$d2/.config/clusters.yaml"
t "catalog placeholder in the private file: says to set it there" 1 "set these in .config/clusters.yaml: REQUIRED-catalogRepoURL" bash "$d2/scripts/clusters.sh" --rows "$d2"
t "  ... so the page-by-page path stays on" 0 "^pp$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && settings_apply && page_by_page && echo pp' "$d"
d=$(repo typo "hub: {api: 'https://h:6443'}
option: {GATE_ROOT_SECONDS: 1}")
t "an unknown top-level key" 1 "unknown keys \(typos\?\): option$" bash "$d/scripts/clusters.sh" --hub
d=$(repo typo2 "hub: {api: 'https://h:6443'}
catalog: {uri: x}
options: {GATE_ROOT_SECOND: 1, KEYCLOAK: install}")
t "unknown catalog and options keys" 1 "unknown keys \(typos\?\): catalog.uri options.GATE_ROOT_SECOND$" bash "$d/scripts/clusters.sh" --hub
d=$(repo typo3 "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', isuer: x}")
t "an unknown site key" 1 "sites\[s1\].isuer" bash "$d/scripts/clusters.sh" --hub
d=$(repo multiline "hub: {api: 'https://h:6443'}
options: {KEYCLOAK: \"a\\nb\"}")
t "a value spanning lines is refused" 1 "spans lines" bash "$d/scripts/clusters.sh" --settings "$d"
d=$(repo smuggle "hub: {api: 'https://h:6443'}
options: {KEYCLOAK: \"a\\nPATH=/evil\"}")
t "a second line that looks like a setting is refused" 1 "spans lines" bash "$d/scripts/clusters.sh" --settings "$d"
t "  ... and prints no setting" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --settings "$0" 2>/dev/null | grep -c PATH= || true' "$d"
d=$(repo keysmuggle "hub: {api: 'https://h:6443'}
options: {\"KEYCLOAK\\nPATH\": /evil}")
t "a key with a line break is refused" 1 "unknown keys" bash "$d/scripts/clusters.sh" --settings "$d"
d=$(repo gatetypo "hub: {api: 'https://h:6443'}
options: {GATE_ROOT_SECOND: 1}")
t "a misspelled GATE_ option" 1 "unknown keys \(typos\?\): options.GATE_ROOT_SECOND$" bash "$d/scripts/clusters.sh" --hub

# The private file: .config/clusters.yaml, read first, the only place for secrets.
SECRET='sha256~SECRET_do_not_print_4242'
priv() { # name body: a repository whose .config/clusters.yaml (mode 600) has that body
  local d; d=$(repo "$1" "hub: {api: 'https://public:6443'}"); mkdir -p "$d/.config"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\n%s\n' "$2" > "$d/.config/clusters.yaml"; chmod 600 "$d/.config/clusters.yaml"
  # make install's catalog, which the private file needs, unless the body sets catalog: or opts out
  case "$2" in *catalog:*|*"# no catalog"*) ;; *) echo "catalog: {url: 'https://github.com/o/c.git'}" >> "$d/.config/clusters.yaml" ;; esac
  echo "$d"
}
PRIV="hub: {api: 'https://private:6443', token: '$SECRET'}
sites:
  - {name: site-b, api: 'https://s:6443', username: admin, password: '$SECRET-pw'}
catalog: {url: 'https://github.com/o/c.git', token: '$SECRET-c'}
deployment: {token: '$SECRET-d'}
quay: {username: 'rhoai+robot', password: '$SECRET-q'}"
d=$(priv private "$PRIV")
t ".config/clusters.yaml wins over clusters.yaml" 0 "^hub hub https://private:6443" bash "$d/scripts/clusters.sh" --rows "$d"
t "secret_get: a token" 0 "^$SECRET-c$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && secret_get .catalog.token' "$d"
t "cluster_secret: a site's inline password" 0 "^$SECRET-pw$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret site-b password' "$d"
t "cluster_secret: a site's inline username" 0 "^admin$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret site-b username' "$d"
t "cluster_secret: the hub's inline token" 0 "^$SECRET$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret hub token' "$d"
t "cluster_secret: unset is empty" 0 "^$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret hub password' "$d"
t "cluster_secret: an unknown cluster" 1 "no cluster nope in" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret nope token' "$d"
t "--rows and --settings print no secret" 0 "^0$" bash -c '{ bash "$0/scripts/clusters.sh" --rows "$0"; bash "$0/scripts/clusters.sh" --settings "$0"; } 2>&1 | grep -c SECRET_do_not_print || true' "$d"
chmod 644 "$d/.config/clusters.yaml"
t "a readable private file stops" 1 "mode 644: run chmod 600 .config/clusters.yaml" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(repo publicsecret "hub: {api: 'https://h:6443'}
quay: {username: x}")
t "secrets in the committed clusters.yaml stop" 1 "can't hold secrets: quay: move them to .config/clusters.yaml" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(priv nocatalog "hub: {api: 'https://h:6443'} # no catalog")
t "private file without a catalog: stops early" 1 "set catalog.url in .config/clusters.yaml" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(priv scalardeploy "hub: {api: 'https://h:6443'}
deployment: '$SECRET-scalar'")
t "deployment: as a value, not a map: named by path" 1 "deployment must be a map" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... the value never printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv scalarsite "hub: {api: 'https://h:6443'}
sites: ['$SECRET-scalar']")
t "a site as a value: named by path" 1 "sites\[0\] must be a map" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... the value never printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv rootsecret "hub: {api: 'https://h:6443'}")
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://h:6443"}\ncatalog: {token: x}\n' > "$d/clusters.yaml"
t "secrets in the committed clusters.yaml stop, even beside a private one" 1 "clusters.yaml is committed, so it can't hold" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(priv credtypo "hub: {api: 'https://h:6443', tokn: x}")
t "a misspelled hub key is named" 1 "unknown keys \(typos\?\): hub.tokn$" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(priv pastedkey "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', '$SECRET-as-a-key': x}")
t "a key that may be a pasted secret: counted, never named" 1 "unknown keys \(typos\?\): sites\[s1\] \(1 unknown key\)$" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... the key never printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv deploykeys "hub: {api: 'https://h:6443'}
deployment: {'$SECRET-as-a-key': x, other: y}")
t "unknown deployment keys: counted, never named" 1 "deployment \(2 unknown keys\)$" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... the key never printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv scalarsites "hub: {api: 'https://h:6443'}
sites: x")
t "a scalar sites: must be a list" 1 "sites must be a list" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(priv placeholder2 "hub: {api: 'https://h:6443'}
catalog: {url: 'https://github.com/o/c.git', token: 'REQUIRED-$SECRET'}")
t "a secret's placeholder: named by key" 1 "set these in .config/clusters.yaml: catalog.token$" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... never by value" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv badyaml "hub: {api: 'https://h:6443'}
quay: {password: '$SECRET' x: }")
t "invalid YAML: names the line, not the text" 1 "isn't valid YAML" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... never the text" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"

# deployment_load: settings and the secret files, for every target.
load() { # dir [VAR=value...] -- shell: runs the shell after deployment_load in a clean HOME
  local d=$1; shift; local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u DEPLOYMENT_TOKEN_FILE -u CATALOG_TOKEN_FILE -u QUAY_AUTH_FILE -u AI_GRID_DEPLOYMENT_TOKEN -u AI_GRID_CATALOG_TOKEN \
    HOME="$T/home" ${envs[@]+"${envs[@]}"} bash -c '. "$0/scripts/clusters.sh"; deployment_load "$0" || exit 1; '"$1" "$d"
}
mkdir -p "$T/home/.ai-grid"; printf 'home-token\n' > "$T/home/.ai-grid/catalog-token"
d=$(priv load "$PRIV")
t "load: deployment token into .config/generated" 0 "^$SECRET-d$" load "$d" -- 'cat "$DEPLOYMENT_TOKEN_FILE"'
t "  ... the file is .config/generated/deployment-token, mode 600" 0 "generated/deployment-token 600$" load "$d" -- 'echo "$DEPLOYMENT_TOKEN_FILE $(stat -f %Lp "$DEPLOYMENT_TOKEN_FILE" 2>/dev/null || stat -c %a "$DEPLOYMENT_TOKEN_FILE")"'
t "  ... its source" 0 "^deployment.token in .config/clusters.yaml$" load "$d" -- 'echo "$DEPLOYMENT_TOKEN_FILE_SOURCE"'
t "  ... the quay.io/rhoai auth file from quay:" 0 "^rhoai\+robot:$SECRET-q$" load "$d" -- 'jq -r ".auths[\"quay.io/rhoai\"].auth" "$QUAY_AUTH_FILE" | base64 -d'
t "  ... AI_GRID_CATALOG_TOKEN wins" 0 "^env-token$" load "$d" AI_GRID_CATALOG_TOKEN=env-token -- 'cat "$CATALOG_TOKEN_FILE"'
t "  ... CATALOG_TOKEN_FILE wins over the file" 0 "^/x/token CATALOG_TOKEN_FILE$" load "$d" CATALOG_TOKEN_FILE=/x/token -- 'echo "$CATALOG_TOKEN_FILE $CATALOG_TOKEN_FILE_SOURCE"'
t "  ... --resolve prints paths and sources, no secret" 0 "^0$" bash -c 'HOME="$1" bash "$0/scripts/clusters.sh" --resolve "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d" "$T/home"
sed -i.bak -e '/^deployment:/d' -e "s|^catalog: .*|catalog: {url: 'https://github.com/o/c.git'}|" "$d/.config/clusters.yaml"; rm "$d/.config/clusters.yaml.bak"
t "  ... a value removed from the file: the generated file goes" 0 "^gone$" load "$d" -- '[ ! -e "$0/.config/generated/deployment-token" ] && [ -z "$DEPLOYMENT_TOKEN_FILE" ] && echo gone'
load "$(priv movetofile "$PRIV")" CATALOG_TOKEN_FILE=/x -- 'true' >/dev/null 2>&1 || true
d2=$(priv movetofile2 "$PRIV"); load "$d2" -- 'true' >/dev/null
t "  ... a secret moved to a *_FILE variable: the generated copy goes" 0 "^gone$" load "$d2" CATALOG_TOKEN_FILE=/x -- '[ ! -e "$0/.config/generated/catalog-token" ] && echo gone'
printf 'legacy\n' > "$d/.config/catalog-token"
t "  ... else the legacy .config/catalog-token" 0 "^legacy$" load "$d" -- 'cat "$CATALOG_TOKEN_FILE"'
t "  ... the missing hint names the key" 0 "deployment.token in .config/clusters.yaml, or AI_GRID_DEPLOYMENT_TOKEN" load "$d" -- 'secret_missing DEPLOYMENT_TOKEN_FILE'
d=$(repo pagebypage "hub: {api: 'https://h:6443'}")
t "page by page: ~/.ai-grid/catalog-token" 0 "^home-token$" load "$d" -- 'cat "$CATALOG_TOKEN_FILE"'
d=$(repo withcatalog "hub: {api: 'https://h:6443'}
catalog: {url: 'https://github.com/o/c.git'}")
t "with a catalog: no home default" 0 "^none$" load "$d" -- '[ -z "$CATALOG_TOKEN_FILE" ] && echo none'
t "settings exported, GATE_ERROR_LIMIT allowed" 0 "^99$" load "$(repo o11y "hub: {api: 'https://h:6443'}
options: {GATE_ERROR_LIMIT: 99}")" -- 'echo "$GATE_ERROR_LIMIT"'
t "WIPE_PROTECT_ isn't an option (nothing reads it)" 1 "options.WIPE_PROTECT_NAMESPACES" bash "$(repo wipe "hub: {api: 'https://h:6443'}
options: {WIPE_PROTECT_NAMESPACES: 'a,b'}")/scripts/clusters.sh" --hub
d=$(priv halfquay "hub: {api: 'https://h:6443'}
quay: {username: u}")
t "quay username without password: stops" 1 "needs both a username and a password" load "$d" -- 'true'
d=$(priv withstage "hub: {api: 'https://h:6443'}
quay: {username: 'rhoai+robot', password: '$SECRET-q'}
stage: {username: 'stage-user', password: '$SECRET-s'}")
t "stage: joins the generated auth file" 0 "^stage-user:$SECRET-s$" load "$d" -- 'jq -r ".auths[\"registry.stage.redhat.io\"].auth" "$QUAY_AUTH_FILE" | base64 -d'
t "  ... beside quay.io/rhoai" 0 "^rhoai\+robot:$SECRET-q$" load "$d" -- 'jq -r ".auths[\"quay.io/rhoai\"].auth" "$QUAY_AUTH_FILE" | base64 -d'
t "  ... --resolve prints no stage secret" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --resolve "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv halfstage "hub: {api: 'https://h:6443'}
quay: {username: u, password: p}
stage: {password: '$SECRET-s'}")
t "stage password without username: stops" 1 "registry.stage.redhat.io login needs both a username and a password" load "$d" -- 'true'
d=$(priv stagefile "hub: {api: 'https://h:6443'}
stage: {username: s, password: '$SECRET-s'}")
printf '{"auths":{}}' > "$d/auth.json"
t "stage: with an auth file: stops, names the file" 1 "stage: in .config/clusters.yaml goes with quay:; QUAY_AUTH_FILE is an auth file" load "$d" QUAY_AUTH_FILE="$d/auth.json" -- 'true'
d=$(priv stagenotstring "hub: {api: 'https://h:6443'}
stage: {username: 123, password: 456}")
printf '{"auths":{}}' > "$d/auth.json"
t "stage: not a string, with an auth file: stops" 1 "stage.username isn't a string" load "$d" QUAY_AUTH_FILE="$d/auth.json" -- 'true'
d=$(repo stagepub "hub: {api: 'https://h:6443'}
stage: {username: x}")
t "stage: in the committed clusters.yaml stops" 1 "can't hold secrets: stage" bash "$d/scripts/clusters.sh" --rows "$d"
t "an unknown key under stage: is named by count" 1 "stage \(1 unknown key\)" load "$(priv stagetypo "hub: {api: 'https://h:6443'}
stage: {username: s, password: p, token: x}")" -- 'true'

# The old format (role:, location:, credentials:, kubeconfig:, hub.name) stops
# first, with what to change, and never prints a value.
old() { # name body want: the old-format message for a private file with that body
  local d; d=$(priv "old-$1" "$2")
  t "old format: $1" 1 "uses the old format.*$3" bash "$d/scripts/clusters.sh" --rows "$d"
  t "  ... no value printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
}
old role "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, role: combined, api: 'https://s:6443'}" "remove role: and location:.*Add to AI Grid"
old location "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, location: us-east, api: 'https://s:6443'}" "remove role: and location:"
old credentials "hub: {api: 'https://h:6443'}
credentials:
  hub: {token: '$SECRET'}" "move each credentials.NAME"
old kubeconfig "hub: {api: 'https://h:6443', kubeconfig: '/k/$SECRET'}" "remove kubeconfig:.*\.config/NAME/kubeconfig"
old site-kubeconfig "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', kubeconfig: /k}" "remove kubeconfig:"
old hub-name "hub: {name: hub, api: 'https://h:6443'}" "remove hub.name"
old repositories "hub: {api: 'https://h:6443'}
repositories: {catalog: 'https://github.com/o/c.git', library: main} # no catalog" "repositories.catalog with catalog.url, repositories.library with options.LIBRARY"
old github "hub: {api: 'https://h:6443'}
github: {catalogToken: '$SECRET', deploymentToken: '$SECRET'}" "github.catalogToken with catalog.token and github.deploymentToken with deployment.token"

# options.LIBRARY is LIBRARY_REVISION; LIBRARY itself (the library checkout) is left alone.
d=$(repo library "hub: {api: 'https://h:6443'}
options: {LIBRARY: v1.2}")
t "options.LIBRARY: the library revision" 0 "^LIBRARY_REVISION=v1.2$" bash "$d/scripts/clusters.sh" --settings "$d"
t "  ... never LIBRARY" 0 "^/my/checkout v1.2$" env LIBRARY=/my/checkout bash -c '. "$0/scripts/clusters.sh"; deployment_load "$0" && echo "$LIBRARY $LIBRARY_REVISION"' "$d"
d=$(repo nolibrary "hub: {api: 'https://h:6443'}")
t "no options.LIBRARY: LIBRARY_REVISION from the environment" 0 "^env-rev$" env LIBRARY_REVISION=env-rev bash -c '. "$0/scripts/clusters.sh"; deployment_load "$0" && echo "$LIBRARY_REVISION"' "$d"
d=$(priv old-first "hub: {name: hub, api: REQUIRED-hubAPIURL}
sites:
  - {name: Bad_Name, role: combined, location: us, api: 'https://s:6443', typo: 1}")
t "old format: reported before placeholders, names and unknown keys" 1 "^error: .config/clusters.yaml uses the old format" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(repo old-committed "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, role: combined, location: us, api: 'https://s:6443'}")
t "old format: the committed file too" 1 "clusters.yaml uses the old format" bash "$d/scripts/clusters.sh" --rows "$d"
d=$(repo spokeskey "hub: {api: 'https://h:6443'}
spokes: []")
t "a top-level spokes: is an unknown key" 1 "unknown keys \(typos\?\): spokes$" bash "$d/scripts/clusters.sh" --rows "$d"

# The committed clusters.yaml holds no secret: not inline on the hub or a site,
# not catalog.token, deployment: or quay:. The path is named, never the value.
pub() { # name body path
  local d; d=$(repo "pub-$1" "$2")
  t "committed file refuses $3" 1 "clusters.yaml is committed, so it can't hold secrets: $3.*\.config/clusters.yaml" bash "$d/scripts/clusters.sh" --rows "$d"
  t "  ... no value printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
}
pub hub-token "hub: {api: 'https://h:6443', token: '$SECRET'}" "hub.token"
pub hub-password "hub: {api: 'https://h:6443', password: '$SECRET'}" "hub.password"
pub hub-username "hub: {api: 'https://h:6443', username: admin}" "hub.username"
pub site-token "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', token: '$SECRET'}" "sites\[s1\].token"
pub site-password "hub: {api: 'https://h:6443'}
sites:
  - {name: s1, api: 'https://s:6443', username: admin, password: '$SECRET'}" "sites\[s1\].username sites\[s1\].password"
pub catalog-token "hub: {api: 'https://h:6443'}
catalog: {url: 'https://github.com/o/c.git', token: '$SECRET'}" "catalog.token"
pub deployment "hub: {api: 'https://h:6443'}
deployment: {token: '$SECRET'}" "deployment"
d=$(repo pub-catalog-url "hub: {api: 'https://h:6443'}
catalog: {url: 'https://github.com/o/c.git'}")
t "committed file may carry catalog.url" 0 "^CATALOG_REPO_URL=https://github.com/o/c.git$" bash "$d/scripts/clusters.sh" --settings "$d"
t "  ... and is then not page by page" 0 "^not-pp$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && settings_apply && { page_by_page && echo pp || echo not-pp; }' "$d"
pub quay "hub: {api: 'https://h:6443'}
quay: {username: u, password: '$SECRET'}" "quay"
d=$(priv pub-beside "hub: {api: 'https://h:6443'}")
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://h:6443"}\nsites:\n  - {name: s1, api: "https://s:6443", password: "%s"}\n' "$SECRET" > "$d/clusters.yaml"
t "committed file refuses an inline password, even beside a private one" 1 "can't hold secrets: sites\[s1\].password" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... no value printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"

d=$(priv pub-github-beside "hub: {api: 'https://h:6443'}")
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://h:6443"}\ngithub: {catalogToken: "%s"}\n' "$SECRET" > "$d/clusters.yaml"
t "committed file with an old github: block stops, even beside a private one" 1 "can't hold secrets: github" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... no value printed" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c SECRET_do_not_print || true' "$d"
d=$(priv pub-repos-beside "hub: {api: 'https://h:6443'}")
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://h:6443"}\nrepositories: {catalog: "https://github.com/o/c.git"}\n' > "$d/clusters.yaml"
t "committed file with old repositories: beside a private one: the old-format message" 1 "^error: clusters.yaml uses the old format: replace repositories.catalog with catalog.url" bash "$d/scripts/clusters.sh" --rows "$d"

# options: with every line commented out is null.
d=$(repo nulloptions "hub: {api: 'https://h:6443'}
options:
  # GATE_ROOT_SECONDS: 600")
t "null options: loads" 0 "^hub hub https://h:6443$" bash "$d/scripts/clusters.sh" --rows "$d"
t "  ... and sets no option" 0 "^$" bash "$d/scripts/clusters.sh" --settings "$d"
t "  ... deployment_load passes" 0 "^ok$" bash -c '. "$0/scripts/clusters.sh"; deployment_load "$0" && echo ok' "$d"

# deployment.token is optional.
d=$(priv nodeploytoken "hub: {api: 'https://h:6443', token: x}
catalog: {url: 'https://github.com/o/c.git', token: '$SECRET-c'}")
t "AI_GRID_DEPLOYMENT_TOKEN still fills the deployment token" 0 "^env-deploy AI_GRID_DEPLOYMENT_TOKEN$" \
  bash -c 'AI_GRID_DEPLOYMENT_TOKEN=env-deploy HOME="$1" bash -c ". \"\$0/scripts/clusters.sh\"; deployment_load \"\$0\" && echo \$(cat \"\$DEPLOYMENT_TOKEN_FILE\") \$DEPLOYMENT_TOKEN_FILE_SOURCE" "$0"' "$(priv envdeploy "hub: {api: 'https://h:6443'}")" "$T/home"
t "no deploymentToken: loads, the deployment token file is empty" 0 "^DEPLOYMENT_TOKEN_FILE=	$" \
  bash -c 'HOME="$1" bash "$0/scripts/clusters.sh" --resolve "$0" 2>&1 | grep ^DEPLOYMENT_TOKEN_FILE=' "$d" "$T/home"

# The acceptance file: as shipped (placeholders), then filled in.
acc() { # name sed-script...: a repository whose .config/clusters.yaml is the acceptance file, filled by perl
  local d; d=$(repo "$1" "hub: {api: 'https://public:6443'}"); rm "$d/clusters.yaml"; mkdir -p "$d/.config"; shift
  perl -pe "$*" "$SRC/tests/fixtures/clusters-acceptance.yaml" > "$d/.config/clusters.yaml"; chmod 600 "$d/.config/clusters.yaml"; echo "$d"
}
d=$(acc accept-placeholders '')
t "acceptance file as shipped: the placeholders, nothing else" 1 "^error: set these in .config/clusters.yaml: .*REQUIRED-hubAPIURL" bash "$d/scripts/clusters.sh" --rows "$d"
for p in REQUIRED-siteName REQUIRED-siteAPIURL hub.username hub.password 'sites\[0\].password' 'sites\[1\].username' REQUIRED-catalogRepoURL catalog.token quay.username quay.password; do
  t "  ... names $p" 1 "$p" bash "$d/scripts/clusters.sh" --rows "$d"
done
t "  ... secrets by path only, never their text" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -cE "REQUIRED-(username|password|catalogToken|quay)" || true' "$d"
t "  ... one error line" 0 "^1$" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" 2>&1 | grep -c . || true' "$d"
FILL='if (/REQUIRED-siteName/) { $n++; s/REQUIRED-siteName/site-$n/ } if (/REQUIRED-siteAPIURL/) { $m++; s|REQUIRED-siteAPIURL|https://api.site-$m.example.com:6443| }
  s|REQUIRED-hubAPIURL|https://api.hub.example.com:6443|; s|REQUIRED-catalogRepoURL|https://github.com/o/c.git|;
  s/REQUIRED-username/admin/; s/REQUIRED-password/fixture-pw/; s/REQUIRED-catalogToken/fixture-catalog/;
  s/REQUIRED-quayUsername/rhoai+robot/; s/REQUIRED-quayPassword/fixture-quay/;'
d=$(acc accept-filled "$FILL")
t "acceptance file filled in: loads, one row each" 0 "^hub hub https://api.hub.example.com:6443 site-1 site https://api.site-1.example.com:6443 site-2 site https://api.site-2.example.com:6443$" \
  bash -c 'echo $(bash "$0/scripts/clusters.sh" --rows "$0")' "$d"
t "  ... cluster_secret: the hub's username" 0 "^admin$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret hub username' "$d"
t "  ... cluster_secret: site-2's password" 0 "^fixture-pw$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret site-2 password' "$d"
t "  ... cluster_api: site-2" 0 "^https://api.site-2.example.com:6443$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_api site-2' "$d"
t "  ... deployment_load: no deployment token, the rest resolved" 0 "^ok$" \
  bash -c '. "$0/scripts/clusters.sh"; deployment_load "$0" && [ -z "$DEPLOYMENT_TOKEN_FILE" ] && [ -s "$CATALOG_TOKEN_FILE" ] && [ -s "$QUAY_AUTH_FILE" ] && echo ok' "$d"
t "  ... settings: no LIBRARY_REVISION by default (the root's pin stands)" 0 "^0$" bash -c 'bash "$0/scripts/clusters.sh" --settings "$0" | grep -c LIBRARY_REVISION || true' "$d"
d=$(acc accept-library "$FILL"' s/^  # LIBRARY: main .*/  LIBRARY: main/;')
t "  ... options.LIBRARY set: that revision" 0 "^LIBRARY_REVISION=main$" bash "$d/scripts/clusters.sh" --settings "$d"
d=$(acc accept-library-empty "$FILL"' s/^  # LIBRARY: main .*/  LIBRARY: ""/;')
t "  ... options.LIBRARY empty: keeps the template's pin" 0 "^LIBRARY_REVISION=$" bash "$d/scripts/clusters.sh" --settings "$d"
t "committed file without options.LIBRARY: no library setting" 0 "^none$" bash -c 'bash "$0/scripts/clusters.sh" --settings "$0" | grep -q LIBRARY_REVISION || echo none' "$(repo nolibrary "hub: {api: 'https://h:6443'}")"
d=$(acc accept-token "$FILL"' s/^(\s*)username: admin\s*$// if $. < 16; s/^(\s*)password: fixture-pw\s*$// if $. < 16; s/^  # token: sha256~TOKEN.*/  token: sha256~fixture/;')
t "acceptance file with a hub token instead: loads" 0 "^sha256~fixture$" bash -c '. "$0/scripts/clusters.sh"; clusters_load "$0" && cluster_secret hub token' "$d"
d=$(acc accept-committed "$FILL"); mv "$d/.config/clusters.yaml" "$d/clusters.yaml"; chmod 644 "$d/clusters.yaml"
t "acceptance file filled in, committed: refused for its secrets" 1 "can't hold secrets: hub.username hub.password sites\[site-1\].username" bash "$d/scripts/clusters.sh" --rows "$d"

# clusters-example.yaml: copied to the committed clusters.yaml (page 2), it
# holds no secret, so filled in it loads page by page.
d=$(repo example "hub: {api: x}"); cp "$SRC/clusters-example.yaml" "$d/clusters.yaml"
t "example as copied: only the placeholder error" 1 "^error: set these in clusters.yaml: REQUIRED-" bash "$d/scripts/clusters.sh" --rows "$d"
perl -i -pe "$FILL" "$d/clusters.yaml"
t "example filled in: loads page by page" 0 "^hub hub https://api.hub.example.com:6443 site-1 site https://api.site-1.example.com:6443$" \
  bash -c 'echo $(bash "$0/scripts/clusters.sh" --rows "$0")' "$d"
t "  ... no secret uncommented" 0 "^0$" bash -c 'grep -cE "^\s*(token|username|password|deployment|quay):" "$0" || true' "$SRC/clusters-example.yaml"

echo "clusters tests: $((total-fails)) ok, $fails failed"; exit "$fails"
