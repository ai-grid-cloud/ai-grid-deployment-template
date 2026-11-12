#!/usr/bin/env bash
# Call a model as a tenant user (install guide, page 7): get the user's token
# from the tenant IdP, then make one chat call through the site's MaaS gateway.
#
#   scripts/tenant-call.sh --user USER --password-file FILE --subscription SUB --model MODEL
#                          [--prompt TEXT] [--site NAME]
#
# The IdP issuer and client come from root/inputs.env and root/kustomization.yaml,
# the client secret from the hub (through its login), and the MaaS host,
# maas.APPS_DOMAIN, from the site (the only site unless --site names one). The
# password, client secret and token stay in files; nothing prints them. It
# prints the reply's text, the HTTP status and the x-grid-site header, and exits
# 1 unless the status is 200.
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

issuer=$(sed -n -E 's/^[[:space:]]*idpIssuerURL[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$dir/root/inputs.env" 2>/dev/null | head -1)
[ -n "$issuer" ] && [ "${issuer#REQUIRED-}" = "$issuer" ] || die "idpIssuerURL isn't set in root/inputs.env (scripts/set-inputs.sh)"
kv() { sed -n -E "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]]+).*/\\1/p" "$dir/root/kustomization.yaml" | head -1; }
client_id=$(kv idpClientID) secret_ns=$(kv idpClientSecretNamespace) secret_name=$(kv idpClientSecretName) secret_key=$(kv idpClientSecretKey)

clusters_load "$dir"
hub=$(hub_name); site=$(site_name "$site")
cluster_login_ok "$hub"; cluster_login_ok "$site"
domain=$(KUBECONFIG=$(cluster_kubeconfig "$site") oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
[ -n "$domain" ] || die "can't read $site's apps domain"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(umask 077
 KUBECONFIG=$(cluster_kubeconfig "$hub") oc get secret "$secret_name" -n "$secret_ns" \
   -o jsonpath="{.data.$secret_key}" | base64 -d > "$tmp/client-secret"
 curl -sS "$issuer/protocol/openid-connect/token" \
   --data-urlencode grant_type=password --data-urlencode "client_id=$client_id" \
   --data-urlencode "client_secret@$tmp/client-secret" --data-urlencode "username=$user" \
   --data-urlencode "password@$pwfile" --data-urlencode scope=openid > "$tmp/token.json")
jq -e -r '.access_token | strings | "Authorization: Bearer " + .' "$tmp/token.json" > "$tmp/auth" 2>/dev/null ||
  die "the IdP gave no token for $user: $(jq -r '.error_description // .error // "no JSON reply"' "$tmp/token.json" 2>/dev/null)"

jq -n --arg m "$model" --arg p "$prompt" '{model: $m, messages: [{role: "user", content: $p}], max_tokens: 20}' > "$tmp/body.json"
code=$(curl -sS -D "$tmp/headers" -o "$tmp/reply" -w '%{http_code}' -H "@$tmp/auth" \
  -H "X-MaaS-Subscription: $sub" -H 'Content-Type: application/json' --data-binary "@$tmp/body.json" \
  "https://maas.$domain/v1/chat/completions")
jq -r '.choices[0].message.content // .error.message // .' "$tmp/reply" 2>/dev/null || cat "$tmp/reply"
echo "HTTP $code"
grep -i '^x-grid-site:' "$tmp/headers" | tr -d '\r' || echo "x-grid-site: (none)"
[ "$code" = 200 ]
