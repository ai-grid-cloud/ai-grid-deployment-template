#!/usr/bin/env bash
# A site's files in this deployment repository (install guide, page 6). On the
# library's main branch there are none to write: the library reads a site's
# values only from its own apps/rhoai/values-<name>.yaml, never from a
# deployment repository, so a site's MaaS gateway can't be pointed at a
# publicly trusted certificate from here. Its HTTPS listener keeps the
# cluster-internal service certificate (docs/upstream-main-limits.md, L4 and L5).
# It says so and writes nothing; it reads no cluster.
#
#   scripts/add-site.sh [NAME] [ISSUER]
#
# NAME defaults to the only site in clusters.yaml. ISSUER is accepted, for the
# same command line as the template's other branches, and unused.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
[ $# -le 2 ] || { echo "usage: add-site.sh [NAME] [ISSUER]" >&2; exit 2; }
clusters_load "$dir"
name=$(site_name "${1:-}")
role=$(cluster_field "$name" role)
case "$role" in
  combined|ingress) ;;
  inference) echo "$name is an inference site: it needs no MaaS files. Next: scripts/join-site.sh $name"; exit 0 ;;
  *) echo "error: $name is the hub" >&2; exit 1 ;;
esac
cat <<MSG
$name ($role): no files to write. The library's main branch reads no per-site
values from this repository, so its MaaS gateway keeps the cluster-internal
certificate, which tenants' clients don't trust (docs/upstream-main-limits.md,
L4 and L5). Next: scripts/join-site.sh $name
MSG
