#!/usr/bin/env bash
# Tests for scripts/set-library.sh against a local bare repository standing in
# for the library, named in a copy of root/kustomization.yaml.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

# The library: a first commit (the old pin) and a branch one commit ahead.
work="$T/lib-work"; mkdir -p "$work"; g -C "$work" init -q
echo one > "$work/f"; g -C "$work" add -A; g -C "$work" commit -qm one
old=$(g -C "$work" rev-parse HEAD)
g -C "$work" checkout -qb feat/next; echo two > "$work/f"; g -C "$work" commit -qam two
new=$(g -C "$work" rev-parse HEAD)
g clone -q --bare "$work" "$T/lib.git"

# A deployment copy whose root names the bare library and pins the old commit.
D="$T/deploy"; mkdir -p "$D"; cp -R "$SRC/scripts" "$SRC/root" "$D/"
k="$D/root/kustomization.yaml"
sed -i.bak -E -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops\.git#$T/lib.git#g" \
  -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops//#file://$T/lib.git//#g" \
  -e "s/[0-9a-f]{40}/$old/g" "$k"; rm "$k.bak"

run() { out=$("$D/scripts/set-library.sh" "$@" 2>&1) && rc=0 || rc=$?; }
count() { grep -o -- "$1" "$k" | wc -l | tr -d ' '; }
yaml_ok() { # every document in the file parses
  python3 - "$k" <<'PY'
import sys
try:
    import yaml
except ImportError:  # no PyYAML: yq parses every document instead
    import subprocess
    sys.exit(subprocess.run(["yq", "-e", "true", sys.argv[1]], capture_output=True).returncode)
docs = list(yaml.safe_load_all(open(sys.argv[1])))
sys.exit(0 if docs and docs[0].get("kind") == "Kustomization" else 1)
PY
}
comments() { grep -c '^ *#' "$k"; }

c0=$(comments)
run feat/next
t "branch: pins its SHA in all three places" \
  eval '[ "$rc" = 0 ] && [ "$(count "$new")" = 3 ] && [ "$(count "$old")" = 0 ] && grep -qF "pinned $T/lib.git at $new (feat/next)" <<<"$out"'
t "  ... the remote base, the generator revision and values.libraryRevision" \
  eval 'grep -q "//bootstrap/hub?ref=$new\$" "$k" && grep -q "path: /spec/generators/0/git/revision, value: $new }" "$k" && grep -q "libraryRevision: $new\$" "$k"'
t "  ... keeps every comment and still parses as YAML" eval '[ "$(comments)" = "$c0" ] && yaml_ok'

sum=$(cksum < "$k")
run feat/next
t "same pin: already pinned" eval '[ "$rc" = 0 ] && grep -q "already pinned" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

run no/such-branch
t "unknown revision: stops" eval '[ "$rc" = 1 ] && grep -q "no/such-branch" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

echo "set-library tests: $((total-fails)) ok, $fails failed"; exit "$fails"
