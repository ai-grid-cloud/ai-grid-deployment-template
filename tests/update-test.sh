#!/usr/bin/env bash
# Tests for scripts/update-from-template.sh against local repositories.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name want_rc expect_grep cmd...
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

# The template: its scripts and a guide file.
tpl="$T/template"; mkdir -p "$tpl"; cp -R "$SRC/scripts" "$tpl/"; echo v1 > "$tpl/guide.md"; echo "hub hub - x" > "$tpl/clusters"
g -C "$tpl" init -q && g -C "$tpl" add -A && g -C "$tpl" commit -qm v1
# A repository created from it ("Use this template"): the same files in a new
# first commit with no shared history; then your clusters.
mine="$T/mine"; mkdir -p "$mine"; cp -R "$tpl/scripts" "$tpl/guide.md" "$tpl/clusters" "$mine/"
g -C "$mine" init -q && g -C "$mine" add -A && g -C "$mine" commit -qm "Initial commit"
echo "hub hub - mine" > "$mine/clusters"; g -C "$mine" commit -qam "my clusters"
echo v2 > "$tpl/guide.md"; g -C "$tpl" commit -qam v2

run() { (cd "$mine" && TEMPLATE_URL="$tpl" bash scripts/update-from-template.sh); }
echo dirty >> "$mine/guide.md"
t "refuses uncommitted changes" 1 "commit or stash your changes first" run
g -C "$mine" checkout -q guide.md
t "first update finds the commit you started from" 0 "started from the template at [0-9a-f]{7}" run
t "takes the template's change" 0 "^v2$" cat "$mine/guide.md"
t "keeps your clusters" 0 "^hub hub - mine$" cat "$mine/clusters"
t "adds the template remote" 0 "^template$" g -C "$mine" remote
t "nothing new" 0 "Already up to date" run
echo v3 > "$tpl/guide.md"; g -C "$tpl" commit -qam v3
t "later update" 0 "Merged the template" run
t "later update takes the change" 0 "^v3$" cat "$mine/guide.md"
echo "mine too" > "$mine/guide.md"; g -C "$mine" commit -qam "my edit"; echo v4 > "$tpl/guide.md"; g -C "$tpl" commit -qam v4
t "a conflict stops with the fix" 1 "conflict.*guide.md" run

echo "update tests: $((total-fails)) ok, $fails failed"; exit "$fails"
