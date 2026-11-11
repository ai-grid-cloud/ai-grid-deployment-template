#!/usr/bin/env bash
# Create a test tenant user in our tenant Keycloak (tenant-idp/), a member of an
# organization the console created, with the attributes the realm's mappers turn
# into MaaS claims: org_id, org_name, groups and roles. Groups are plain names
# (such as ai-grid-users): MaaS prefixes them with org_id itself and drops any
# group that already starts with an organization ID (flat claims, ADR PR 181).
#
# A real tenant's users come from the tenant's own identity provider; this user
# exists only to prove the end-to-end call (prototype goal 3).
#
# The user's password is generated into PASSWORD_FILE (mode 600) if missing. No
# secret is printed or put on a command line.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: create-test-tenant.sh --kubeconfig PATH --org NAME --user NAME --password-file PATH
                             [--group ai-grid-users] [--role users] [--namespace tenant-idp] [--realm tenants]
EOF
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

kubeconfig="" org="" user="" password_file="" group=ai-grid-users role=users ns=tenant-idp realm=tenants
while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig) kubeconfig="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --user) user="$2"; shift 2 ;;
    --password-file) password_file="$2"; shift 2 ;;
    --group) group="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --namespace) ns="$2"; shift 2 ;;
    --realm) realm="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[ -n "$kubeconfig" ] && [ -n "$org" ] && [ -n "$user" ] && [ -n "$password_file" ] || { usage >&2; exit 2; }
for c in oc curl jq openssl; do command -v "$c" >/dev/null || die "required command not found: $c"; done
k() { oc --kubeconfig "$kubeconfig" "$@"; }

host="$(k get route keycloak -n "$ns" -o jsonpath='{.spec.host}')"
[ -n "$host" ] || die "route $ns/keycloak has no host"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
(umask 077
 k get secret keycloak-secrets -n "$ns" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d > "$tmp/admin-user"
 k get secret keycloak-secrets -n "$ns" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d > "$tmp/admin-pass")
token="$(curl -fsS "https://$host/realms/master/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
  --data-urlencode "username@$tmp/admin-user" --data-urlencode "password@$tmp/admin-pass" | jq -r .access_token)"
[ -n "$token" ] && [ "$token" != null ] || die "Keycloak admin sign-in failed"
printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"; chmod 600 "$tmp/auth"
api() { curl -fsS -H "@$tmp/auth" -H 'Content-Type: application/json' "$@"; }
base="https://$host/admin/realms/$realm"

# The maas_* attributes are unmanaged: the user profile must let an admin set
# them, or Keycloak drops them silently and tokens carry no org claims. The
# realm import's user-profile component isn't applied by Keycloak 26.8, and the
# library sets this in its realm-sync step, which tenant-idp/ leaves out.
profile="$(api "$base/users/profile")"
if [ "$(printf '%s' "$profile" | jq -r '.unmanagedAttributePolicy // ""')" != ADMIN_EDIT ]; then
  printf '%s' "$profile" | jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' | api -X PUT "$base/users/profile" -d @- >/dev/null
  echo "Set the realm's user profile to let admins set unmanaged attributes."
fi

org_id="$(api "$base/organizations?search=$(jq -rn --arg o "$org" '$o|@uri')&exact=true" | jq -r --arg o "$org" '.[] | select(.name==$o) | .id')"
[ -n "$org_id" ] || die "no organization named $org in realm $realm (create it in the console first)"

if [ ! -s "$password_file" ]; then
  # No trailing newline: curl's --data-urlencode password@FILE would send it.
  (umask 077; printf '%s' "$(openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-24)" > "$password_file")
  echo "Generated a password in $password_file."
fi

attrs="$(jq -n --arg id "$org_id" --arg name "$org" --arg g "$group" --arg r "$role" \
  '{maas_org_id: [$id], maas_org_name: [$name], maas_groups: [$g], maas_roles: [$r]}')"
user_id="$(api "$base/users?username=$(jq -rn --arg u "$user" '$u|@uri')&exact=true" | jq -r '.[0].id // empty')"
if [ -z "$user_id" ]; then
  api -X POST "$base/users" -d "$(jq -n --arg u "$user" --argjson a "$attrs" \
    '{username: $u, enabled: true, emailVerified: true, email: ($u + "@example.invalid"), firstName: $u, lastName: "test", attributes: $a}')" >/dev/null
  user_id="$(api "$base/users?username=$(jq -rn --arg u "$user" '$u|@uri')&exact=true" | jq -r '.[0].id')"
  echo "Created user $user."
else
  api "$base/users/$user_id" | jq --argjson a "$attrs" '.attributes = ((.attributes // {}) + $a)' |
    api -X PUT "$base/users/$user_id" -d @- >/dev/null
  echo "Updated user $user."
fi
jq -n --rawfile p "$password_file" '{type: "password", temporary: false, value: ($p | rtrimstr("\n"))}' |
  api -X PUT "$base/users/$user_id/reset-password" -d @- >/dev/null
api -X POST "$base/organizations/$org_id/members" -d "\"$user_id\"" >/dev/null 2>&1 || true
api "$base/organizations/$org_id/members?search=$(jq -rn --arg u "$user" '$u|@uri')" | jq -e --arg u "$user" 'any(.[]; .username==$u)' >/dev/null ||
  die "$user is not a member of $org"
echo "$user is in $org ($org_id), group $group (MaaS sees $org_id/$group), role $role."
