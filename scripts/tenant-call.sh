#!/usr/bin/env bash
# Call a model as a tenant user (install guide, page 7): get the user's token
# from the tenant IdP, then make one chat call through the site's MaaS gateway.
#
#   scripts/tenant-call.sh --user USER --password-file FILE --subscription SUB --model MODEL
#                          [--prompt TEXT] [--site NAME]
#
# The IdP is the library's Keycloak, the only tenant IdP on its main branch:
# realm saas at Route maas-db/keycloak on the hub, client tenant-demo, its
# secret from Secret maas-db/keycloak-secrets (KEYCLOAK_CLIENT_SECRET), through
# the hub's login. The MaaS host, maas.APPS_DOMAIN, comes from the site (the
# only site unless --site names one). The password, client secret and token stay
# in files; nothing prints them. It prints the reply's text, the HTTP status and
# the x-grid-site header, and exits 1 unless the status is 200.
#
# Two limits of the library's main branch stop it, and it names them when they
# do (docs/upstream-main-limits.md): client tenant-demo has no password grant
# (L6), and the MaaS gateway presents the cluster-internal certificate (L5).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage="usage: tenant-call.sh --user USER --password-file FILE --subscription SUB --model MODEL [--prompt TEXT] [--site NAME]"
user="" pwfile="" sub="" model="" prompt="Say hello in five words." site=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
  case "$1" in
    --user) user=$2 ;; --password-file) pwfile=$2 ;; --subscription) sub=$2 ;; --model) model=$2 ;;
    --prompt) prompt=$2 ;; --site) site=$2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2
done
[ -n "$user" ] && [ -n "$pwfile" ] && [ -n "$sub" ] && [ -n "$model" ] || { echo "$usage" >&2; exit 2; }
[ -s "$pwfile" ] || die "no password in $pwfile"

client_id=tenant-demo secret_ns=maas-db secret_name=keycloak-secrets secret_key=KEYCLOAK_CLIENT_SECRET

clusters_load "$dir"
hub=$(hub_name); site=$(site_name "$site")
cluster_login_ok "$hub"; cluster_login_ok "$site"
domain=$(KUBECONFIG=$(cluster_kubeconfig "$site") oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
[ -n "$domain" ] || die "can't read $site's apps domain"
kc_host=$(KUBECONFIG=$(cluster_kubeconfig "$hub") oc get route keycloak -n maas-db -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$kc_host" ] || die "no Route maas-db/keycloak on the hub: is the keycloak Application Synced and Healthy? (make status)"
issuer="https://$kc_host/realms/saas"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(umask 077
 KUBECONFIG=$(cluster_kubeconfig "$hub") oc get secret "$secret_name" -n "$secret_ns" \
   -o jsonpath="{.data.$secret_key}" | base64 -d > "$tmp/client-secret"
 curl -sS "$issuer/protocol/openid-connect/token" \
   --data-urlencode grant_type=password --data-urlencode "client_id=$client_id" \
   --data-urlencode "client_secret@$tmp/client-secret" --data-urlencode "username=$user" \
   --data-urlencode "password@$pwfile" --data-urlencode scope=openid > "$tmp/token.json")
if ! jq -e -r '.access_token | strings | "Authorization: Bearer " + .' "$tmp/token.json" > "$tmp/auth" 2>/dev/null; then
  why=$(jq -r '.error_description // .error // "no JSON reply"' "$tmp/token.json" 2>/dev/null || echo "no JSON reply")
  if [ "$(jq -r '.error // ""' "$tmp/token.json" 2>/dev/null)" = unauthorized_client ]; then
    die "the IdP gave no token for $user: $why. The library's client $client_id has no password grant on its main branch (docs/upstream-main-limits.md, L6); call the model with an API key from the MaaS portal instead"
  fi
  die "the IdP gave no token for $user: $why"
fi

jq -n --arg m "$model" --arg p "$prompt" '{model: $m, messages: [{role: "user", content: $p}], max_tokens: 20}' > "$tmp/body.json"
rc=0
code=$(curl -sS -D "$tmp/headers" -o "$tmp/reply" -w '%{http_code}' -H "@$tmp/auth" \
  -H "X-MaaS-Subscription: $sub" -H 'Content-Type: application/json' --data-binary "@$tmp/body.json" \
  "https://maas.$domain/v1/chat/completions" 2>"$tmp/curl.err") || rc=$?
case "$rc" in
  0) ;;
  60) die "https://maas.$domain/: its certificate is not trusted: on the library's main branch the MaaS gateway presents the cluster-internal certificate (docs/upstream-main-limits.md, L5)" ;;
  *) die "https://maas.$domain/: $(grep . "$tmp/curl.err" | tail -n1)" ;;
esac
jq -r '.choices[0].message.content // .error.message // .' "$tmp/reply" 2>/dev/null || cat "$tmp/reply"
echo "HTTP $code"
grep -i '^x-grid-site:' "$tmp/headers" | tr -d '\r' || echo "x-grid-site: (none)"
[ "$code" = 200 ]
