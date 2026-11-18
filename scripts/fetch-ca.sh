#!/usr/bin/env bash
# Fetches the CA certificates a cluster presents and writes them into the
# cluster's ca: in clusters.yaml, so make login and the other scripts trust it.
#
#   scripts/fetch-ca.sh NAME          (make fetch-ca NAME=...) NAME is hub or a site's name
#   FORCE=1 scripts/fetch-ca.sh NAME  replaces a ca: the cluster already has
#
# A new cluster's API server and its OAuth server, which the ingress router
# serves, often present certificates that no public CA signed. This script
# reads the certificate chain each one presents, with openssl s_client
# -showcerts, from the cluster's API host and from oauth-openshift.apps.DOMAIN.
# It takes DOMAIN from the API URL, https://api.DOMAIN:6443, because that's how
# OpenShift names the two: api.DOMAIN for the API and *.apps.DOMAIN for the
# router. From each chain it keeps the self-signed certificates, else the last
# one, the top of what the server sent, without duplicates; it warns when one it
# keeps isn't a self-signed CA, since that can change. When the OAuth host
# doesn't answer, it keeps the API's alone and warns. It prints each one's
# subject, issuer and SHA-256 fingerprint: compare the fingerprints with what a
# cluster admin who already trusts the cluster sees before you rely on them
# (trust on first use).
#
# It writes them as a block scalar, ca: |, on the line after the cluster's api:
# line, in the file the scripts read: .config/clusters.yaml when it exists, else
# clusters.yaml. A CA isn't a secret, so the committed file can hold it. The
# rest of the file, comments included, stays as it is, and the file changes
# only when the result loads and holds exactly these certificates. When the
# cluster has a ca: already and FORCE isn't 1, or the layout isn't one it can
# edit, such as a flow-style entry ({api: ...}), it changes nothing, prints the
# ca: block for you to paste, and exits 1.
#
# It never turns certificate checks off: s_client prints the chain a server
# presents whether or not it verifies it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
TIMEOUT=${FETCH_CA_TIMEOUT:-15}   # seconds for each server to answer

name=${1:-}
[ -n "$name" ] || { echo "error: name a cluster: make fetch-ca NAME=hub, or a site's name" >&2; exit 2; }
clusters_load "$here/.." || exit 1
api=$(cluster_api "$name") || exit 1
file=$CLUSTERS_FILE rel=${CLUSTERS_FILE#"$CLUSTERS_DIR/"}

hostport=${api#https://}; hostport=${hostport%%/*}
host=${hostport%%:*} port=443
[ "$host" = "$hostport" ] || port=${hostport##*:}
case "$host" in
  api.?*) oauth="oauth-openshift.apps.${host#api.}" ;;
  *) echo "error: $name: can't work out the apps domain: the API host $host isn't api.DOMAIN; put the cluster's CA in a file and set ca: to its path" >&2; exit 1 ;;
esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

with_timeout() { # SECONDS CMD...: runs CMD, stopping it after SECONDS
  local secs=$1 pid watch rc; shift
  "$@" & pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & watch=$!
  wait "$pid" && rc=0 || rc=$?
  kill "$watch" 2>/dev/null || true
  return "$rc"
}

subject() { openssl x509 -noout -subject -nameopt RFC2253 -in "$1" | sed 's/^subject= *//'; }
issuer() { openssl x509 -noout -issuer -nameopt RFC2253 -in "$1" | sed 's/^issuer= *//'; }
fingerprint() { openssl x509 -noout -fingerprint -sha256 -in "$1" | sed 's/^[^=]*=//'; }
is_ca() { openssl x509 -noout -text -in "$1" | grep -A1 'Basic Constraints' | grep -q 'CA:TRUE'; }

seen=" " n=0
top_of() { # HOST PORT: adds the top certificates of HOST:PORT's chain to $tmp/ca.pem
  local h=$1 p=$2 d="$tmp/$1" f last="" tops=() fp
  mkdir -p "$d"
  with_timeout "$TIMEOUT" openssl s_client -showcerts -connect "$h:$p" -servername "$h" </dev/null >"$d/chain" 2>"$d/err" || true
  awk -v pre="$d/" '/-----BEGIN CERTIFICATE-----/ { f = sprintf("%s%03d.pem", pre, ++i) }
    f { print > f } /-----END CERTIFICATE-----/ { close(f); f = "" }' "$d/chain"
  for f in "$d"/[0-9]*.pem; do
    [ -f "$f" ] || break
    last=$f
    [ "$(subject "$f")" != "$(issuer "$f")" ] || tops+=("$f")
  done
  [ -n "$last" ] || { echo "error: $name: no certificate from $h:$p: $(grep . "$d/err" | tail -n 1 || echo 'is it reachable?')" >&2; return 1; }
  [ ${#tops[@]} -gt 0 ] || tops=("$last")
  for f in "${tops[@]}"; do
    fp=$(fingerprint "$f")
    case "$seen" in *" $fp "*) continue ;; esac
    seen="$seen$fp " n=$((n+1))
    openssl x509 -in "$f" >> "$tmp/ca.pem"
    printf '%s:%s\n  subject: %s\n  issuer: %s\n  SHA-256 fingerprint: %s\n' "$h" "$p" "$(subject "$f")" "$(issuer "$f")" "$fp"
    if [ "$(subject "$f")" != "$(issuer "$f")" ] || ! is_ca "$f"; then
      echo "  warning: $(subject "$f") isn't a self-signed CA, but the top of what $h sent: it may change when the cluster renews its certificates"
    fi
  done
}

top_of "$host" "$port" || exit 1
# Without the router's CA, a login with a password, and calls to the hub's
# Routes, may still fail; the API's CA is worth keeping anyway.
top_of "$oauth" 443 2>"$tmp/oauth.err" ||
  echo "warning: skipped $oauth:443 ($(sed 's/^error: [^:]*: //' "$tmp/oauth.err")): ca: holds only the API's CA, so a login with a password, which goes through the router, may still fail; run make fetch-ca again when the router answers" >&2
echo "Compare each SHA-256 fingerprint with what a cluster admin who already trusts $name sees, such as with"
echo "oc get configmap kube-root-ca.crt -n default and the router's certificate, before you rely on it."

paste_block() { # WHY: prints the ca: block to paste, then exits 1
  echo
  echo "$rel unchanged: $1. Put this in $name's entry in $rel, at the indentation of its api: line:"
  echo
  echo "ca: |"; sed 's/^/  /' "$tmp/ca.pem"
  exit 1
}

has_ca=$(jq -r --arg n "$name" '(if $n == "hub" then .hub else first(.sites[] | select(.name == $n)) end) | has("ca")' <<<"$CLUSTERS_JSON")
[ "$has_ca" = false ] || [ "${FORCE:-}" = 1 ] || paste_block "$name has a ca: already; FORCE=1 replaces it"

# The edit, line by line. Pass 1 finds the cluster's entry: the hub: block, or
# the sites: item whose name: is NAME, its keys' indentation, its api: line and
# any ca: (with the lines of its value). Pass 2 drops that ca: and writes the
# new one after api:.
awk -v target="$name" -v pem="$tmp/ca.pem" '
  function indent(s) { match(s, /^ */); return RLENGTH }
  function value(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/^["\047]|["\047]$/, "", s); return s }
  NR == FNR {
    line = $0
    if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) { top = line; sub(/:.*/, "", top); keys = 0; inca = 0; next }
    if (inca) {
      if (line ~ /^[ \t]*$/) next
      if (indent(line) > keys) { caends[caentry] = FNR; next }
      inca = 0
    }
    if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) next
    if (top == "hub" && target == "hub") { if (!keys) keys = indent(line); entry = "hub" }
    else if (top == "sites" && target != "hub") {
      if (line ~ /^ *- /) { item++; keys = indent(line) + 2; sub(/- /, "  ", line) }
      entry = item
    } else next
    if (indent(line) != keys) next
    k = line; sub(/^ */, "", k); sub(/:.*/, "", k)
    if (k == "name" && value(line) == target) found = entry
    if (k == "api") { api[entry] = FNR; ind[entry] = keys }
    if (k == "ca") { cas[entry] = FNR; caends[entry] = FNR; caentry = entry; inca = 1 }
    next
  }
  FNR == 1 {
    if (target == "hub") found = "hub"
    if (found == "" || !(found in api)) { print "no-api" > "/dev/stderr"; exit 3 }
    at = api[found]; k = ind[found]
  }
  { print_it = 1 }
  (found in cas) && FNR >= cas[found] && FNR <= caends[found] { print_it = 0 }
  print_it { print }
  FNR == at {
    printf "%*sca: |\n", k, ""
    while ((getline l < pem) > 0) printf "%*s%s\n", k + 2, "", l
  }
' "$file" "$file" > "$tmp/new" 2>"$tmp/awk.err" || paste_block "can't find $name's api: line on a line of its own"

# Keep the edit only when the file still loads as before, apart from this one
# cluster's ca:, which now holds exactly the certificates fetched.
check='def c($n): if $n == "hub" then .hub else first(.sites[] | select(.name == $n)) end;
  def rest($n): if $n == "hub" then del(.hub.ca) else .sites |= map(if .name == $n then del(.ca) else . end) end;'
old=$(jq -c --arg n "$name" "$check rest(\$n)" <<<"$CLUSTERS_JSON")
if ! new=$(KUBECONFIG=/dev/null kubectl label --local -f "$tmp/new" ai-grid.dev/read=true -o json 2>/dev/null) ||
   [ "$(jq -c --arg n "$name" "$check rest(\$n)" <<<"$new")" != "$old" ] ||
   [ "$(jq -r --arg n "$name" "$check c(\$n).ca" <<<"$new")" != "$(cat "$tmp/ca.pem")" ]; then
  paste_block "the edited file didn't load as expected"
fi
cat "$tmp/new" > "$file"   # in place, so the file keeps its mode
echo
echo "Wrote $n certificate(s) to $name's ca: in $rel.$([ "$rel" = clusters.yaml ] && echo " Commit it with your other changes.")"
