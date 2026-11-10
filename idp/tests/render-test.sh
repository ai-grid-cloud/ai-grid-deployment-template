#!/usr/bin/env bash
# Checks idp/ offline: kustomize builds it, and the realm renders to valid JSON
# with realm tenants and client ai-grid-tenants carrying the six claim mappers
# MaaS reads. Run from anywhere: bash idp/tests/render-test.sh
set -Eeuo pipefail

idp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "kustomize build idp/"
kustomize build "$idp_dir" > "$work/idp.yaml"

echo "render the realm with dummy values"
KEYCLOAK_CLIENT_SECRET=dummy-client-secret \
TENANT_PORTAL_REDIRECT_URI='https://maas.apps.example.invalid/*' \
  bash "$idp_dir/manifests/scripts/render-realm.sh" \
  < "$idp_dir/manifests/realms/tenants-realm.json" > "$work/tenants-realm.json"

echo "a missing value fails the render"
if env -u KEYCLOAK_CLIENT_SECRET TENANT_PORTAL_REDIRECT_URI=x \
  bash "$idp_dir/manifests/scripts/render-realm.sh" \
  < "$idp_dir/manifests/realms/tenants-realm.json" > /dev/null 2>&1; then
  echo "FAIL: render succeeded without KEYCLOAK_CLIENT_SECRET" >&2
  exit 1
fi

python3 -I - "$work/tenants-realm.json" "$work/idp.yaml" <<'PY'
import json, re, sys

realm_path, manifests_path = sys.argv[1], sys.argv[2]
text = open(realm_path).read()
failures = []

def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)

realm = json.loads(text)
check(not re.search(r"\$\{[A-Z_]+\}", text), "no unrendered ${...} placeholder")
check(realm.get("realm") == "tenants", "realm is tenants")
check(realm.get("organizationsEnabled") is True, "organizations enabled")
clients = {c["clientId"]: c for c in realm.get("clients", [])}
check(list(clients) == ["ai-grid-tenants"], "one client, ai-grid-tenants")
client = clients.get("ai-grid-tenants", {})
check(client.get("secret") == "dummy-client-secret", "client secret rendered")
check(client.get("publicClient") is False, "client is confidential")
check(client.get("directAccessGrantsEnabled") is True, "password grant on (prototype)")
check(client.get("redirectUris") == ["https://maas.apps.example.invalid/*"], "redirect URI rendered")
mappers = {m["name"]: m for m in client.get("protocolMappers", [])}
check(len(mappers) == 6, "six protocol mappers (found %d)" % len(mappers))
claims = {m["config"].get("claim.name") for m in mappers.values()}
check({"groups", "org_id", "org_name", "roles", "token_use"} <= claims,
      "claims groups, org_id, org_name, roles, token_use")
aud = [m for m in mappers.values() if m["protocolMapper"] == "oidc-audience-mapper"]
check(len(aud) == 1 and aud[0]["config"].get("included.client.audience") == "ai-grid-tenants",
      "audience mapper names ai-grid-tenants")
check("users" not in realm and "identityProviders" not in realm, "no users or broker IdPs")

manifests = open(manifests_path).read()
check("kind: Secret\n" not in manifests, "no literal Secret in the build")
sys.exit(1 if failures else 0)
PY
echo PASS
