#!/usr/bin/env bash
# Reads a deployment repository's clusters.yaml: .config/clusters.yaml when it
# exists (private: git-ignored, mode 600, and the only place secrets may go),
# else clusters.yaml at the root (copied from clusters-example.yaml). It says
# only how to reach each cluster: the hub and each site with its API URL, its
# optional ca: (cluster_ca) and,
# in the private file only, its token or username and password;
# the catalog repository (catalog.url; its token, catalog.token, in the private
# file only); make install's settings (options:); and, in the private file
# only, deployment.token, quay: and stage:. Roles and locations aren't in it: the
# provider console's Add to AI Grid sets them. The hub's name is always "hub".
# Each cluster's login is .config/NAME/kubeconfig (git-ignored; make login).
# kubectl parses the YAML offline (--local), and jq reads the result. No error
# quotes a secret.
#
# Sourced by the other scripts:
#   clusters_load DIR             reads and checks DIR/.config/clusters.yaml, else DIR/clusters.yaml
#   CLUSTERS_FILE                 the file it read
#   CLUSTERS_ROWS                 one line per cluster: NAME KIND API, KIND hub or site
#   secret_get JQ_PATH            a secret's value, such as .catalog.token; empty when unset
#   cluster_secret NAME KEY       the cluster's own token, username or password; empty when unset
#   deployment_load DIR           clusters_load, then the settings and the secret files
#                                 exported (see "settings and secrets" below)
#   settings_lines                its install settings, KEY=VALUE per line
#   hub_name, site_names          the hub's name; the sites' names
#   site_name [NAME]              NAME, or the only site when NAME is empty;
#                                 with several sites, asks you to name one
#   grid_site [NAME]              as site_name, but the hub when there is no site
#   acm_name NAME                 the ManagedCluster: local-cluster for the hub
#   cluster_api NAME              the cluster's API URL
#   cluster_kubeconfig NAME       the path of NAME's kubeconfig
#   cluster_ca NAME               the CA file to check NAME against, "ignore", or nothing
#   cluster_tls NAME              sets CURL_TLS, OC_TLS and KUBECONFIG_TLS from cluster_ca
#   merge_kubeconfigs HUB SITE OUT  one kubeconfig with contexts hub and site
#   INSTALL_NS_RE                 an extended regex matching the namespaces an
#                                 install creates on a hub or a site

CLUSTERS_DIR="" CLUSTERS_ROWS="" CLUSTERS_JSON="" CLUSTERS_FILE=""
# The keys clusters.yaml's options: may hold (make install's settings).
# GATE_O11Y_SECONDS and GATE_TENANT_IDP_SECONDS are accepted and unused: earlier
# versions read them, and a private file may still set them.
SETTINGS_OPTIONS_RE='KEYCLOAK|ALLOW_GENERIC_LOGIN|PROVIDER_ADMIN_TOKEN_DURATION|GATE_ROOT_SECONDS|GATE_MCH_SECONDS|GATE_HUB_APPS_SECONDS|GATE_SITE_IMPORT_SECONDS|GATE_READY_SECONDS|GATE_INTERVAL|GATE_ERROR_LIMIT|GATE_O11Y_SECONDS|GATE_TENANT_IDP_SECONDS'
INSTALL_NS_RE='open-cluster-management|multicluster-engine|redhat-ods|redhat-ai-grid|maas|ai-grid|gitops|kuadrant|submariner'

# The old format's keys on stdin's JSON, as what to change, "; "-separated.
# Keys only, never a value.
_old_format() {
  jq -r '
      def entries: [(.hub | objects), ((.sites // []) | arrays | .[] | objects)];
      (if has("repositories") or has("github") then "replace repositories.catalog with catalog.url, repositories.library with options.LIBRARY, github.catalogToken with catalog.token and github.deploymentToken with deployment.token" else empty end),
      (if has("credentials") then "move each credentials.NAME token, or username and password, into that cluster'"'"'s own hub: or sites: entry, and copy a credentials.NAME.kubeconfig to .config/NAME/kubeconfig" else empty end),
      (if (.hub | objects | has("name")) then "remove hub.name (the hub is always hub)" else empty end),
      (if any(entries[]; has("role") or has("location")) then "remove role: and location: (choose them in the provider console'"'"'s Add to AI Grid)" else empty end),
      (if any(entries[]; has("kubeconfig")) then "remove kubeconfig: (copy that kubeconfig to .config/NAME/kubeconfig instead)" else empty end)
      ' 2>/dev/null | paste -sd ';' - | sed 's/;/; /g'
}

clusters_load() {
  CLUSTERS_DIR=$(cd "${1:-.}" && pwd)
  local f json cjson rows="" what name kind api left mode private="" rel
  if [ -f "$CLUSTERS_DIR/.config/clusters.yaml" ]; then f="$CLUSTERS_DIR/.config/clusters.yaml" private=1
  else f="$CLUSTERS_DIR/clusters.yaml"; fi
  CLUSTERS_FILE=$f rel=${f#"$CLUSTERS_DIR/"}
  [ -f "$f" ] || { echo "error: no clusters.yaml: copy clusters-example.yaml to .config/clusters.yaml (or clusters.yaml) and edit it (install guide, page 2 or 9)" >&2; return 1; }
  if [ -n "$private" ]; then
    mode=$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")
    [[ "$mode" =~ 00$ ]] || { echo "error: .config/clusters.yaml holds secrets and is mode $mode: run chmod 600 .config/clusters.yaml" >&2; return 1; }
  fi
  # kubectl's message can quote the file, which may hold secrets: keep only its line number.
  if ! json=$(KUBECONFIG=/dev/null kubectl label --local -f "$f" ai-grid.dev/read=true -o json 2>&1); then
    left=$(grep -oE 'line [0-9]+' <<<"$json" | head -n 1 || true)
    echo "error: $rel isn't valid YAML${left:+ (at $left)}" >&2; return 1
  fi
  [ "$(jq -r .kind <<<"$json")" = Clusters ] || { echo "error: clusters.yaml needs kind: Clusters" >&2; return 1; }
  # The old format, first: say what to change.
  left=$(_old_format <<<"$json")
  [ -z "$left" ] || { echo "error: $rel uses the old format: $left (see clusters-example.yaml)" >&2; return 1; }
  # The committed clusters.yaml never holds secrets, whichever file is read.
  if [ -f "$CLUSTERS_DIR/clusters.yaml" ]; then
    if ! cjson=$(KUBECONFIG=/dev/null kubectl label --local -f "$CLUSTERS_DIR/clusters.yaml" ai-grid.dev/read=true -o json 2>/dev/null) ||
       ! left=$(jq -r '
        def secrets($p): objects | ["token", "username", "password"][] as $k | select(has($k)) | "\($p).\($k)";
        (.hub | secrets("hub")),
        ((.sites // []) | arrays | to_entries[] | .key as $i | .value | objects
          | secrets("sites[\(.name | if type == "string" and test("\\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\z") then . else $i end)]")),
        (.catalog | objects | select(has("token")) | "catalog.token"),
        (["credentials", "github", "deployment", "quay", "stage"][] as $k | select(has($k)) | $k)' <<<"$cjson" 2>/dev/null); then
      echo "error: clusters.yaml isn't valid YAML" >&2; return 1
    fi
    left=$(tr '\n' ' ' <<<"$left"); left=${left% }
    [ -z "$left" ] || { echo "error: clusters.yaml is committed, so it can't hold secrets: $left: move them to .config/clusters.yaml (chmod 600), which git ignores" >&2; return 1; }
    # Beside the private file, an old committed file would otherwise go unnoticed.
    left=$(_old_format <<<"$cjson")
    [ -z "$left" ] || { echo "error: clusters.yaml uses the old format: $left (see clusters-example.yaml)" >&2; return 1; }
  fi
  # Each of these is a map; a value in its place is named by path only, never printed.
  left=$(jq -r '
      ([["options"], ["catalog"], ["deployment"], ["hub"], ["quay"], ["stage"]][] as $p
        | select(getpath($p) | . != null and type != "object") | $p | join(".")),
      ((.sites // []) | if type == "array" then to_entries[] | select((.value | type) != "object") | "sites[\(.key)]" else "sites must be a list" end)
      ' <<<"$json" 2>/dev/null | head -n 1) ||
    { echo "error: $rel: can't read its structure" >&2; return 1; }
  case "$left" in
    "") ;;
    *" must be a list") echo "error: $rel: $left" >&2; return 1 ;;
    *) echo "error: $rel: $left must be a map" >&2; return 1 ;;
  esac
  # Options that named secret files before the secrets moved into the private file.
  left=$(jq -r '(.options // {}) | keys[] | select(. == "DEPLOYMENT_TOKEN_FILE" or . == "CATALOG_TOKEN_FILE" or . == "QUAY_AUTH_FILE")' <<<"$json" | head -n 1)
  case "$left" in
    "") ;;
    DEPLOYMENT_TOKEN_FILE) echo "error: options.$left is no longer read: put the token in deployment.token in .config/clusters.yaml, and delete the option" >&2; return 1 ;;
    CATALOG_TOKEN_FILE) echo "error: options.$left is no longer read: put the token in catalog.token in .config/clusters.yaml, and delete the option" >&2; return 1 ;;
    *) echo "error: options.$left is no longer read: put the quay.io/rhoai robot account in quay.username and quay.password in .config/clusters.yaml, and delete the option" >&2; return 1 ;;
  esac
  # A key the scripts don't read is a typo, most likely: name it.
  left=$(jq -r --arg opts "\\A(LIBRARY|$SETTINGS_OPTIONS_RE)\\z" '
      def count($p): if length == 0 then [] else ["\($p) (\(length) unknown key\(if length > 1 then "s" else "" end))"] end;
      # Beside a secret, a key may itself be a pasted secret: name only a short word, else count.
      def word: test("\\A[A-Za-z][A-Za-z0-9_-]{0,31}\\z");
      def beside($p): (map(select(word)) | map("\($p).\(.)")) + (map(select(word | not)) | count($p));
      (keys - ["apiVersion", "kind", "metadata", "hub", "sites", "catalog", "deployment", "options", "quay", "stage"] | map(.)),
      ((.catalog // {}) | keys - ["url", "token"] | beside("catalog")),
      ((.deployment // {}) | keys - ["token"] | count("deployment")),
      ((.quay // {}) | keys - ["username", "password"] | count("quay")),
      ((.stage // {}) | keys - ["username", "password"] | count("stage")),
      ((.hub // {}) | keys - ["api", "token", "username", "password", "ca"] | beside("hub")),
      ((.sites // []) | to_entries[] | .key as $i | (.value // {})
        | (.name | if type == "string" and test("\\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\z") then . else $i end) as $ref
        | (keys - ["name", "api", "token", "username", "password", "ca", "maasCertificate"] | beside("sites[\($ref)]"))),
      ((.options // {}) | keys | map(select(test($opts) | not)) | map("options." + .))
      | .[]' <<<"$json" | tr '\n' ' ')
  [ -z "$left" ] || { echo "error: clusters.yaml: unknown keys (typos?): ${left% }" >&2; return 1; }
  # Placeholders, before the checks on names and URLs: a setting's own text; a
  # secret's path, never its value. In the committed file the catalog URL's
  # is allowed: it means no catalog yet (settings_lines).
  left=$(jq -r '
      # A site is named by its name when that is a DNS label (not a placeholder), else by its index.
      def site_ref($root; $i): ($root.sites[$i].name) as $n
        | if ($n | type) == "string" and ($n | test("\\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\z")) then $n else $i end;
      def path_text($root): (if .[0] == "sites" and (.[1] | type) == "number" then ["sites[\(site_ref($root; .[1]))]"] + .[2:] else . end)
        | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".") | gsub("\\.\\["; "[");
      def secret_paths: paths(strings) | select(.[0] == "deployment" or .[0] == "quay" or .[0] == "stage" or . == ["catalog", "token"]
        or ((.[0] == "hub" or .[0] == "sites") and (.[-1] | IN("token", "username", "password"))));
      ([secret_paths] as $s | (if $private then . else del(.catalog.url) end) | reduce $s[] as $p (.; delpaths([$p]))
        | .. | strings | select(test("REQUIRED-")) | match("REQUIRED-[A-Za-z]+").string),
      (. as $root | secret_paths as $p | select(getpath($p) | test("REQUIRED-")) | $p | path_text($root))' --argjson private "$([ -n "$private" ] && echo true || echo false)" <<<"$json" | awk '!seen[$0]++' | tr '\n' ' ')
  [ -z "$left" ] || { echo "error: set these in $rel: ${left% }" >&2; return 1; }
  # One tab-separated row per cluster: what (hub or site N), name, kind, api.
  while IFS=$'\t' read -r what name kind api; do
    [ -n "$name" ] && [ -n "$api" ] ||
      { echo "error: clusters.yaml: $what needs $([ "$what" = hub ] || echo 'name and ')api" >&2; return 1; }
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "error: clusters.yaml: $what name $name isn't a DNS label" >&2; return 1; }
    [[ "$api" =~ ^https:// ]] || { echo "error: clusters.yaml: $what api $api isn't an https URL" >&2; return 1; }
    case " $(awk '{print $1}' <<<"$rows" | tr '\n' ' ') " in *" $name "*) echo "error: clusters.yaml: the name $name is used twice" >&2; return 1 ;; esac
    rows+="$name $kind $api"$'\n'
  done < <(jq -r '(["hub", "hub", "hub", .hub.api]),
      ((.sites // []) | to_entries[] | ["site \(.key + 1)", .value.name, "site", .value.api])
      | map(. // "" | tostring) | @tsv' <<<"$json")
  # maasCertificate was the template's per-site MaaS certificate, which the
  # library's main branch can't attach (docs/upstream-main-limits.md).
  left=$(jq -r '[(.sites // [])[] | select(has("maasCertificate")) | .name][0] // empty' <<<"$json")
  [ -z "$left" ] || { echo "error: $rel: sites[$left].maasCertificate: remove it: on the library's main branch a site's MaaS gateway keeps the cluster's internal certificate (docs/upstream-main-limits.md)" >&2; return 1; }
  # The private file is for make install, which needs the catalog: say so now, not later.
  [ -z "$private" ] || [ -n "$(jq -r '.catalog.url // "" | select(startswith("REQUIRED-") | not)' <<<"$json")" ] ||
    { echo "error: set catalog.url in .config/clusters.yaml" >&2; return 1; }
  CLUSTERS_ROWS=$rows CLUSTERS_JSON=$json
  # ca: ignore turns certificate checks off for that cluster: say so on every run, once per
  # cluster, even when a script runs another (AI_GRID_CA_IGNORE_WARNED is inherited).
  for name in $(jq -r '[(.hub | objects | select(.ca == "ignore") | "hub"), ((.sites // [])[] | objects | select(.ca == "ignore") | .name)][]' <<<"$json"); do
    case " ${AI_GRID_CA_IGNORE_WARNED:-} " in *" $name "*) continue ;; esac
    echo "$name: TLS verification off (ca: ignore); your password is sent unverified" >&2
    AI_GRID_CA_IGNORE_WARNED="${AI_GRID_CA_IGNORE_WARNED:-} $name"; export AI_GRID_CA_IGNORE_WARNED
  done
}

secret_get() { # JQ_PATH: the secret's value on stdout, empty when unset; it never reaches a command line
  jq -r "($1) // empty | if type == \"string\" then . else error(\"not a string\") end" <<<"$CLUSTERS_JSON" 2>/dev/null ||
    { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: ${1#.} isn't a string" >&2; return 1; }
}

cluster_secret() { # NAME KEY: the hub's, or the site entry's, own token, username or password
  cluster_api "$1" >/dev/null || return 1
  case "$2" in token|username|password) ;; *) echo "error: unknown credential $2" >&2; return 1 ;; esac
  jq -r --arg n "$1" --arg k "$2" '(if $n == "hub" then .hub else first(.sites[] | select(.name == $n)) end)[$k] // empty
    | if type == "string" then . else error("not a string") end' <<<"$CLUSTERS_JSON" 2>/dev/null ||
    { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: $([ "$1" = hub ] && echo hub || echo "sites[$1]").$2 isn't a string" >&2; return 1; }
}

# The install settings clusters.yaml holds, as KEY=VALUE lines, one for each
# key the file sets (an empty value too, so it wins over the environment):
# catalog.url is CATALOG_REPO_URL, options.LIBRARY is LIBRARY_REVISION (not
# LIBRARY, which names the library checkout; nothing when left out, so the
# root's pin stands), and each other options key is
# itself. true is 1, false and null
# are empty.
settings_lines() {
  # A value spread over lines would come out as more than one setting: refuse it.
  jq -r '
    def v: if . == true then "1" elif . == false or . == null then ""
      else tostring | if test("[\\n\\r]") then error("a setting'"'"'s value spans lines") else . end end;
    # REQUIRED-catalogRepoURL (the example) means no catalog yet, as "" does.
    (if (.catalog // {}) | has("url") then
      "CATALOG_REPO_URL=\(.catalog.url | v | if startswith("REQUIRED-") then "" else . end)" else empty end),
    # options.LIBRARY repins the library; without it, the pin in root/applicationset.yaml stands.
    (if (.options // {}) | has("LIBRARY") then "LIBRARY_REVISION=\(.options.LIBRARY | v)" else empty end),
    ((.options // {}) | to_entries[] | select(.key != "LIBRARY") | "\(.key)=\(.value | v)")' \
    --argjson private "$(clusters_private && echo true || echo false)" <<<"$CLUSTERS_JSON" 2>/dev/null ||
    { echo "error: clusters.yaml: a setting's value spans lines" >&2; return 1; }
}

hub_name() { awk '$2 == "hub" {print $1}' <<<"$CLUSTERS_ROWS"; }
site_names() { awk '$2 == "site" {print $1}' <<<"$CLUSTERS_ROWS"; }

site_name() { # [NAME]
  local n=${1:-} all count
  all=$(site_names)
  if [ -n "$n" ]; then
    grep -qx -- "$n" <<<"$all" || { echo "error: $n isn't a site in clusters.yaml: $(echo $all | sed 's/ /, /g')" >&2; return 1; }
    echo "$n"; return 0
  fi
  count=$(grep -c . <<<"$all" || true)
  case "$count" in
    1) echo "$all" ;;
    0) echo "error: clusters.yaml has no site" >&2; return 1 ;;
    *) echo "error: name a site: $(echo $all | sed 's/ /, /g')" >&2; return 1 ;;
  esac
}

# A site to call or show: NAME, or the only site. With no site in
# clusters.yaml (an all-in-one), the hub, which joins the grid as local-cluster.
grid_site() { # [NAME]
  if [ -z "${1:-}" ] && [ -z "$(site_names)" ]; then hub_name; else site_name "${1:-}"; fi
}
acm_name() { if [ "$1" = "$(hub_name)" ]; then echo local-cluster; else echo "$1"; fi; } # NAME -> its ManagedCluster

cluster_api() { # NAME
  local v; v=$(awk -v n="$1" '$1 == n {print $3}' <<<"$CLUSTERS_ROWS")
  [ -n "$v" ] || { echo "error: no cluster $1 in ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}" >&2; return 1; }
  echo "$v"
}

cluster_kubeconfig() { cluster_api "$1" >/dev/null && echo "$CLUSTERS_DIR/.config/$1/kubeconfig"; }

# The CA a cluster's API and OAuth servers are checked against, from its ca: in
# clusters.yaml. A CA isn't a secret, so either file may hold it:
#   ca: ignore              no check at all (not recommended; a warning on every run)
#   ca: PATH                a PEM file, relative to the repository, absolute, or ~/...
#   ca: |                   the PEM itself, written to .config/generated/NAME-ca.crt
#     -----BEGIN CERTIFICATE-----
# Left out, .config/NAME/ca.crt when that file exists, else the system's trust.
cluster_ca() { # NAME: prints the CA file, the word ignore, or nothing (the system's trust)
  local name=$1 v f ref
  cluster_api "$name" >/dev/null || return 1
  if [ "$name" = hub ]; then ref=hub.ca; else ref="sites[$name].ca"; fi
  v=$(jq -r --arg n "$name" '(if $n == "hub" then .hub else first(.sites[] | select(.name == $n)) end).ca // empty
    | if type == "string" then . else error("not a string") end' <<<"$CLUSTERS_JSON" 2>/dev/null) ||
    { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: $ref isn't a string" >&2; return 1; }
  case "$v" in
    "") f="$CLUSTERS_DIR/.config/$name/ca.crt"; [ ! -f "$f" ] || echo "$f" ;;
    ignore) echo ignore ;;
    "-----BEGIN CERTIFICATE-----"*) printf '%s\n' "$v" | _generated "$name-ca.crt" ;;
    *) [[ "$v" != *$'\n'* ]] || { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: $ref is neither ignore, a file's path, nor PEM starting with -----BEGIN CERTIFICATE-----" >&2; return 1; }
       f=$(_abs "$v")
       [ -f "$f" ] && [ -r "$f" ] || { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: $ref: $v: no such file" >&2; return 1; }
       echo "$f" ;;
  esac
}

# cluster_tls NAME sets, from cluster_ca, the options that make each tool check
# NAME's certificates: CURL_TLS for curl, OC_TLS for oc login, KUBECONFIG_TLS
# for a kubeconfig's cluster entry. Only ca: ignore turns the check off; nothing
# else in these scripts may.
cluster_tls() { # NAME
  local ca; ca=$(cluster_ca "$1") || return 1
  CURL_TLS=() OC_TLS=() KUBECONFIG_TLS=""
  case "$ca" in
    "") ;;
    ignore) CURL_TLS=(--insecure) OC_TLS=(--insecure-skip-tls-verify=true) KUBECONFIG_TLS="    insecure-skip-tls-verify: true"$'\n' ;; # ca: ignore only
    *) CURL_TLS=(--cacert "$ca") OC_TLS=(--certificate-authority="$ca")
       KUBECONFIG_TLS="    certificate-authority: '${ca//\'/\'\'}'"$'\n' ;;   # YAML single quotes: ' doubled
  esac
}

cluster_login_ok() { # NAME: exits non-zero, with the fix, when there's no working login
  local k; k=$(cluster_kubeconfig "$1") || return 1
  [ -f "$k" ] || { echo "error: no login for $1: run make login NAME=$1" >&2; return 1; }
  # A login that skips certificate checks is only for ca: ignore: once ca: changes, it's rebuilt.
  if grep -qE '^[[:space:]]*insecure-skip-tls-verify:[[:space:]]*true' "$k" && [ "$(cluster_ca "$1" 2>/dev/null)" != ignore ]; then # ca: ignore check
    echo "error: $1: its login skips certificate checks, but its ca: isn't ignore: run make login NAME=$1" >&2; return 1
  fi
  KUBECONFIG=$k oc whoami >/dev/null 2>&1 || { echo "error: $1: login expired: run make login NAME=$1" >&2; return 1; }
}

merge_kubeconfigs() { # HUB SITE OUT: renames each cluster, user and context, so equal names in the two files can't collide
  local out=$3 alias name tmp; tmp=$(mktemp -d); : > "$out"; chmod 600 "$out"
  for alias in hub site; do
    if [ "$alias" = hub ]; then name=$1; else name=$2; fi
    KUBECONFIG=$(cluster_kubeconfig "$name") oc config view --raw --flatten --minify -o json |
      jq --arg a "$alias" '.clusters[0].name = $a | .users[0].name = $a
        | .contexts[0].name = $a | .contexts[0].context.cluster = $a | .contexts[0].context.user = $a
        | .["current-context"] = $a' > "$tmp/$alias.json" || { rm -rf "$tmp"; return 1; }
  done
  KUBECONFIG="$tmp/hub.json:$tmp/site.json" oc config view --raw --flatten > "$out"
  rm -rf "$tmp"
}

# --- settings and secrets for every target --------------------------------
#
# deployment_load DIR: clusters_load, then make install's settings and the
# secret files, exported for this script and the ones it runs.
#
# Settings (settings_lines): a value the file holds, even an empty one, wins
# over the environment's; one it leaves out comes from the environment.
#
# Secrets: each becomes a file the scripts pass on by path, never a command line:
#   DEPLOYMENT_TOKEN_FILE   AI_GRID_DEPLOYMENT_TOKEN, else DEPLOYMENT_TOKEN_FILE,
#                           else deployment.token, else .config/deployment-token
#   CATALOG_TOKEN_FILE      AI_GRID_CATALOG_TOKEN, else CATALOG_TOKEN_FILE, else
#                           catalog.token, else .config/catalog-token, else
#                           (page by page) ~/.ai-grid/catalog-token
#   QUAY_AUTH_FILE          AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD, else
#                           QUAY_AUTH_FILE, else quay:, else .config/quay-auth.json,
#                           else (page by page) ~/.config/containers/auth.json or
#                           $XDG_RUNTIME_DIR/containers/auth.json. A generated file
#                           also carries stage: (registry.stage.redhat.io).
# A value (from AI_GRID_* or the private file) is written to .config/generated/
# (mode 600, rewritten on every load, removed when the value goes). "Page by
# page" means no .config/clusters.yaml and no catalog setting. VAR_SOURCE says
# where each came from; secret_missing VAR prints the fix when there's none.
SETTINGS_KEYS_RE='CATALOG_REPO_URL|LIBRARY_REVISION'

deployment_load() { # DIR
  clusters_load "$1" || return 1
  settings_apply || return 1
  secrets_apply
}

settings_apply() {
  local lines line key value
  lines=$(settings_lines) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*} value=${line#*=}
    # Only a known setting becomes a variable, never PATH or the like.
    [[ "$key" =~ ^($SETTINGS_KEYS_RE|$SETTINGS_OPTIONS_RE)$ ]] ||
      { echo "error: ${CLUSTERS_FILE#"$CLUSTERS_DIR/"}: unknown setting $key" >&2; return 1; }
    printf -v "$key" '%s' "$value"; export "${key?}"
  done <<<"$lines"
  for key in $(compgen -v GATE_); do
    [[ "$key" != GATE_* || "${!key}" =~ ^[0-9]+$ ]] ||
      { echo "error: $key must be a number of seconds, not ${!key}" >&2; return 1; }
  done
}

clusters_private() { [ "$CLUSTERS_FILE" = "$CLUSTERS_DIR/.config/clusters.yaml" ]; }
page_by_page() { ! clusters_private && [ -z "${CATALOG_REPO_URL:-}" ]; }

_generated() { # NAME: writes stdin to .config/generated/NAME (mode 600) and prints its path
  local g="$CLUSTERS_DIR/.config/generated"
  ( umask 077; mkdir -p "$g"; cat > "$g/$1.new" ) && chmod 700 "$CLUSTERS_DIR/.config" "$g" &&
    chmod 600 "$g/$1.new" && mv -f "$g/$1.new" "$g/$1" && echo "$g/$1"
}

_abs() { case "$1" in /*) echo "$1" ;; "~/"*) echo "$HOME/${1#"~/"}" ;; *) echo "$CLUSTERS_DIR/$1" ;; esac; }

_secret_file() { # VAR ENV JQ_PATH NAME [HOME_DEFAULT]
  local var=$1 env=$2 path=$3 name=$4 home=${5:-} v="" f="" src=""
  v=${!env:-}; [ -z "$v" ] || src=$env
  if [ -z "$v" ] && [ -n "${!var:-}" ]; then
    f=$(_abs "${!var}") src=$var
    [ "$f" = "$CLUSTERS_DIR/.config/generated/$name" ] || rm -f "$CLUSTERS_DIR/.config/generated/$name"
  else
    if [ -z "$v" ]; then v=$(secret_get "$path") || return 1; [ -z "$v" ] || src="${path#.} in .config/clusters.yaml"; fi
    if [ -n "$v" ]; then
      f=$(printf '%s\n' "$v" | _generated "$name") || return 1
    else
      rm -f "$CLUSTERS_DIR/.config/generated/$name"
      if [ -s "$CLUSTERS_DIR/.config/$name" ]; then f="$CLUSTERS_DIR/.config/$name" src=".config/$name"
      elif [ -n "$home" ] && page_by_page && [ -s "$home" ]; then f=$home src=$home; fi
    fi
  fi
  printf -v "$var" '%s' "$f"; printf -v "${var}_SOURCE" '%s' "$src"; export "${var?}" "${var}_SOURCE"
}

_stage_auth() { # base64 of stage.username:stage.password, empty when stage: is unset
  local u p
  u=$(secret_get .stage.username) && p=$(secret_get .stage.password) || return 1
  if [ -n "$u" ] && [ -n "$p" ]; then printf '%s' "$u:$p" | base64 | tr -d '\n'
  elif [ -n "$u$p" ]; then echo "error: the registry.stage.redhat.io login needs both a username and a password (stage: in .config/clusters.yaml)" >&2; return 1
  fi
}

_quay_auth() {
  local u p f="" src="" b64 h stage
  u=${AI_GRID_QUAY_USERNAME:-} p=${AI_GRID_QUAY_PASSWORD:-}
  [ -z "$u$p" ] || src="AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD"
  if [ -z "$u$p" ] && [ -n "${QUAY_AUTH_FILE:-${RHOAI_QUAY_AUTH_FILE:-}}" ]; then
    f=$(_abs "${QUAY_AUTH_FILE:-$RHOAI_QUAY_AUTH_FILE}") src=QUAY_AUTH_FILE
    [ "$f" = "$CLUSTERS_DIR/.config/generated/quay-auth.json" ] || rm -f "$CLUSTERS_DIR/.config/generated/quay-auth.json"
  else
    if [ -z "$u$p" ]; then
      u=$(secret_get .quay.username) && p=$(secret_get .quay.password) || return 1
      [ -z "$u$p" ] || src="quay: in .config/clusters.yaml"
    fi
    if [ -n "$u" ] && [ -n "$p" ]; then
      b64=$(printf '%s' "$u:$p" | base64 | tr -d '\n')
      stage=$(_stage_auth) || return 1
      # printf is a builtin, so the logins never reach a command line; base64 needs no JSON escaping.
      if [ -n "$stage" ]; then
        f=$(printf '{"auths":{"quay.io/rhoai":{"auth":"%s"},"registry.stage.redhat.io":{"auth":"%s"}}}\n' "$b64" "$stage" |
            _generated quay-auth.json) || return 1
      else
        f=$(printf '{"auths":{"quay.io/rhoai":{"auth":"%s"}}}\n' "$b64" | _generated quay-auth.json) || return 1
      fi
    elif [ -n "$u$p" ]; then
      echo "error: the quay.io/rhoai login needs both a username and a password ($src)" >&2; return 1
    else
      rm -f "$CLUSTERS_DIR/.config/generated/quay-auth.json"
      if [ -s "$CLUSTERS_DIR/.config/quay-auth.json" ]; then f="$CLUSTERS_DIR/.config/quay-auth.json" src=.config/quay-auth.json
      elif page_by_page; then
        for h in "$HOME/.config/containers/auth.json" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/containers/auth.json}"; do
          [ -n "$h" ] && [ -f "$h" ] && { f=$h src=$h; break; }
        done
      fi
    fi
  fi
  if [ -n "$f" ] && [ "$f" != "$CLUSTERS_DIR/.config/generated/quay-auth.json" ]; then
    u=$(secret_get .stage.username) && p=$(secret_get .stage.password) || return 1
    [ -z "$u$p" ] ||
      { echo "error: stage: in .config/clusters.yaml goes with quay:; $src is an auth file, so put the registry.stage.redhat.io login in it instead" >&2; return 1; }
  fi
  QUAY_AUTH_FILE=$f QUAY_AUTH_FILE_SOURCE=$src; export QUAY_AUTH_FILE QUAY_AUTH_FILE_SOURCE
}

secrets_apply() {
  _secret_file DEPLOYMENT_TOKEN_FILE AI_GRID_DEPLOYMENT_TOKEN .deployment.token deployment-token || return 1
  _secret_file CATALOG_TOKEN_FILE AI_GRID_CATALOG_TOKEN .catalog.token catalog-token "$HOME/.ai-grid/catalog-token" || return 1
  _quay_auth
}

secret_missing() { # VAR: how to supply it
  case "$1:$(page_by_page && echo pp)" in
    DEPLOYMENT_TOKEN_FILE:*) echo "set deployment.token in .config/clusters.yaml, or AI_GRID_DEPLOYMENT_TOKEN" ;;
    CATALOG_TOKEN_FILE:pp) echo "save it in ~/.ai-grid/catalog-token, or set CATALOG_TOKEN_FILE (install guide, page 2)" ;;
    CATALOG_TOKEN_FILE:*) echo "set catalog.token in .config/clusters.yaml, or AI_GRID_CATALOG_TOKEN" ;;
    QUAY_AUTH_FILE:pp) echo "set QUAY_AUTH_FILE to a container auth file with a quay.io/rhoai login" ;;
    QUAY_AUTH_FILE:*) echo "set quay.username and quay.password in .config/clusters.yaml, or AI_GRID_QUAY_USERNAME and AI_GRID_QUAY_PASSWORD" ;;
  esac
}

# scripts/clusters.sh --rows DIR prints one line per cluster (name kind api,
# kind hub or site), or the error; prereqs.py uses it. scripts/clusters.sh --settings DIR
# prints settings_lines (install.sh and prereqs.py). scripts/clusters.sh --site [NAME]
# prints site_name's answer for this repository (the Makefile's SITE=), and
# scripts/clusters.sh --hub the hub's name.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --rows ]; then
  clusters_load "${2:-.}" && printf '%s' "$CLUSTERS_ROWS"
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --settings ]; then
  clusters_load "${2:-.}" && settings_lines
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --resolve ]; then
  # VAR=PATH<tab>SOURCE for each secret file (make prereqs); never a secret's value.
  deployment_load "${2:-.}" && for v in DEPLOYMENT_TOKEN_FILE CATALOG_TOKEN_FILE QUAY_AUTH_FILE; do
    s="${v}_SOURCE"; printf '%s=%s\t%s\n' "$v" "${!v}" "${!s}"; done
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --hub ]; then
  clusters_load "$(dirname "$0")/.." && hub_name
elif [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --site ]; then
  clusters_load "$(dirname "$0")/.." && site_name "${2:-}"
fi
