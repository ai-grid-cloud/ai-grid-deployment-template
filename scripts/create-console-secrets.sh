#!/usr/bin/env bash
# Runs the library's apps/console/create-secrets.sh at your pin (install guide,
# page 4). Takes the same environment variables; see that script.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/library.sh"
library_dir "$here/.."
exec bash "$LIB/apps/console/create-secrets.sh" "$@"
