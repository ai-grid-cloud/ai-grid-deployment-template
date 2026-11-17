#!/usr/bin/env bash
# Call a model as a tenant (install guide, page 7): one chat call through the
# site's MaaS gateway with an API key a tenant user created in the Org UI.
#
#   scripts/tenant-call.sh --key-file FILE --model MODEL [--subscription SUB]
#                          [--prompt TEXT] [--site NAME]
#
# FILE holds the API key and nothing else: create the key in the Org UI at
# https://maas.SITE_APPS_DOMAIN/maas-portal and save it there. The MaaS host,
# maas.SITE_APPS_DOMAIN, comes from the site (the only site unless --site names
# one). --subscription sends X-MaaS-Subscription, for a user in several. The key
# stays in files; nothing prints it. It prints the reply's text, the HTTP status
# and the x-grid-site header, and exits 1 unless the status is 200.
#
# On the library's main branch the MaaS gateway presents the cluster's internal
# certificate, which curl doesn't trust; it says so when that stops the call
# (docs/upstream-main-limits.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage="usage: tenant-call.sh --key-file FILE --model MODEL [--subscription SUB] [--prompt TEXT] [--site NAME]"
keyfile="" sub="" model="" prompt="Say hello in five words." site=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
  case "$1" in
    --key-file) keyfile=$2 ;; --subscription) sub=$2 ;; --model) model=$2 ;;
    --prompt) prompt=$2 ;; --site) site=$2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift 2
done
[ -n "$keyfile" ] && [ -n "$model" ] || { echo "$usage" >&2; exit 2; }
[ -s "$keyfile" ] || die "no API key in $keyfile: create one in the Org UI and save it there"
[ "$(tr -d '\r\n' < "$keyfile" | grep -c '[[:space:]]')" = 0 ] || die "$keyfile must hold only the API key"

clusters_load "$dir"
site=$(site_name "$site")
cluster_login_ok "$site"
domain=$(KUBECONFIG=$(cluster_kubeconfig "$site") oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
[ -n "$domain" ] || die "can't read $site's apps domain"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(umask 077; { printf 'Authorization: Bearer '; tr -d '\r\n' < "$keyfile"; printf '\n'
  [ -z "$sub" ] || printf 'X-MaaS-Subscription: %s\n' "$sub"; } > "$tmp/headers-in")
jq -n --arg m "$model" --arg p "$prompt" '{model: $m, messages: [{role: "user", content: $p}], max_tokens: 20}' > "$tmp/body.json"
rc=0
code=$(curl -sS -D "$tmp/headers" -o "$tmp/reply" -w '%{http_code}' -H "@$tmp/headers-in" \
  -H 'Content-Type: application/json' --data-binary "@$tmp/body.json" \
  "https://maas.$domain/v1/chat/completions" 2>"$tmp/curl.err") || rc=$?
case "$rc" in
  0) ;;
  60) die "https://maas.$domain/: its certificate is not trusted: on the library's main branch the MaaS gateway presents the cluster's internal certificate (docs/upstream-main-limits.md)" ;;
  *) die "https://maas.$domain/: $(grep . "$tmp/curl.err" | tail -n1)" ;;
esac
jq -r '.choices[0].message.content // .error.message // .' "$tmp/reply" 2>/dev/null || cat "$tmp/reply"
echo "HTTP $code"
grep -i '^x-grid-site:' "$tmp/headers" | tr -d '\r' || echo "x-grid-site: (none)"
[ "$code" = 200 ]
