#!/usr/bin/env bash
# Tests for scripts/library.sh against a local bare repository standing in for
# the library, named in a copy of root/applicationset.yaml. No network.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0 rc=0 out=""
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

# The library: main with one commit, pushed to a bare repository.
work="$T/lib-work"; mkdir -p "$work"; g -C "$work" init -q
echo one > "$work/f"; g -C "$work" add -A; g -C "$work" commit -qm one
one=$(g -C "$work" rev-parse HEAD)
g clone -q --bare "$work" "$T/lib.git"; g -C "$work" remote add origin "$T/lib.git"
advance() { echo "$1" > "$work/f"; g -C "$work" commit -qam "$1"; g -C "$work" push -q origin main; g -C "$work" rev-parse HEAD; }

# A deployment copy whose root names the bare library at REVISION.
D="$T/deploy"; mkdir -p "$D"; cp -R "$SRC/scripts" "$SRC/root" "$D/"
set_rev() {
  sed -i.bak -E -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops\.git#file://$T/lib.git#g" \
    -e "s#^([[:space:]]*libraryRevision: &libraryRevision )[^[:space:]]+#\1$1#" "$D/root/applicationset.yaml"
  rm "$D/root/applicationset.yaml.bak"
}
run() { out=$(env -u LIBRARY "$D/scripts/library.sh" "$@" 2>&1) && rc=0 || rc=$?; }
head_of() { git -C "$1" rev-parse HEAD; }

set_rev main
run
t "branch: fetches the branch's tip into .library/ and prints its path" \
  eval '[ "$rc" = 0 ] && [ "$(tail -n1 <<<"$out")" = "$D/.library" ] && [ "$(head_of "$D/.library")" = "$one" ]'
run
t "  ... again with no change: the same commit, nothing checked out" \
  eval '[ "$rc" = 0 ] && [ "$(head_of "$D/.library")" = "$one" ] && ! grep -q "checked out" <<<"$out"'
two=$(advance two)
run
t "  ... the branch moved: .library/ follows it" \
  eval '[ "$rc" = 0 ] && [ "$(head_of "$D/.library")" = "$two" ] && grep -q "checked out" <<<"$out"'

# The library unreachable: the branch as last fetched, with a warning; with
# nothing fetched yet, it stops and says why.
mv "$T/lib.git" "$T/lib.gone"
run
t "branch, library unreachable: warns with git's reason, uses the branch as last fetched" \
  eval '[ "$rc" = 0 ] && grep -q "couldn.t reach the library: fatal: .*; using main as last fetched, ${two:0:12}" <<<"$out" && [ "$(tail -n1 <<<"$out")" = "$D/.library" ]'
mv "$D/.library" "$T/cached-library"
run
t "  ... and nothing fetched yet: stops, with git's reason" \
  eval '[ "$rc" = 1 ] && grep -q "couldn.t fetch branch main from .*: fatal: .*does not appear to be a git repository" <<<"$out"'
mv "$T/cached-library" "$D/.library"; mv "$T/lib.gone" "$T/lib.git"

set_rev "$one"
run
t "full SHA: .library/ at that commit, not the branch's tip" \
  eval '[ "$rc" = 0 ] && [ "$(head_of "$D/.library")" = "$one" ]'

set_rev no-such-branch
run
t "a branch the library doesn't have: stops" eval '[ "$rc" = 1 ] && grep -q "no-such-branch" <<<"$out"'

# LIBRARY: your own checkout, never fetched.
mine="$T/mine"; g clone -q "$T/lib.git" "$mine"
lib() { out=$(env LIBRARY="$mine" "$D/scripts/library.sh" 2>&1) && rc=0 || rc=$?; }
set_rev main
lib
t "LIBRARY on the branch: used as it is" eval '[ "$rc" = 0 ] && [ "$(tail -n1 <<<"$out")" = "$mine" ]'
g -C "$mine" checkout -q --detach "$one"
lib
t "LIBRARY off the branch: stops, says how to move it" \
  eval '[ "$rc" = 1 ] && grep -q "isn.t at the tip of main" <<<"$out" && grep -q "checkout main" <<<"$out"'
set_rev "$one"
lib
t "LIBRARY at the pinned SHA: used" eval '[ "$rc" = 0 ] && [ "$(tail -n1 <<<"$out")" = "$mine" ]'
set_rev "$two"
lib
t "LIBRARY off the pinned SHA: stops, as before" eval '[ "$rc" = 1 ] && grep -q "isn.t at your pin $two" <<<"$out"'

set_rev ""
run
t "no libraryRevision: stops" eval '[ "$rc" = 1 ] && grep -q "no libraryRevision" <<<"$out"'

echo "library tests: $((total-fails)) ok, $fails failed"; exit "$fails"
