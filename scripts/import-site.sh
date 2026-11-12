#!/usr/bin/env bash
# Runs the library's ACM import script at your pin (install guide, page 5):
# docs/acm/cluster-onboarding/import-managed-cluster.sh. Takes the same
# arguments and environment variables; see that script.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
library_dir "$here/.."
exec bash "$LIB/docs/acm/cluster-onboarding/import-managed-cluster.sh" "$@"
