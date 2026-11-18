#!/usr/bin/env bash
# Tests for scripts/sync-guide-pin.sh on a copy of this repository's guide, with
# a stub git that answers ls-remote for the library (no network).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0 rc=0 out=""
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

# The library's main is at MAIN; any other ls-remote finds nothing.
MAIN=1111111111111111111111111111111111111111
mkdir -p "$T/bin"; REAL_GIT=$(command -v git)
cat > "$T/bin/git" <<STUB
#!/bin/bash
if [ "\$1" = ls-remote ]; then
  echo "\$*" >> "$T/ls-remote.log"
  case " \$* " in *" main "*|*" refs/heads/main "*) printf '%s\trefs/heads/main\n' "$MAIN" ;; esac
  exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$T/bin/git"

D="$T/deploy"; mkdir -p "$D/docs"; cp -R "$SRC/scripts" "$SRC/root" "$SRC/README.md" "$D/"; cp -R "$SRC/docs/install" "$D/docs/"
run() { out=$(cd "$D" && env PATH="$T/bin:$PATH" scripts/sync-guide-pin.sh "$@" 2>&1) && rc=0 || rc=$?; }
links() { grep -rhoE 'ai-grid-cluster-gitops/blob/[0-9a-f]{40}/' "$D/README.md" "$D/docs/install" | sort -u; }
web=https://github.com/ai-grid-cloud/ai-grid-cluster-gitops
OLD=$(links | head -n1 | sed -E 's#.*/blob/([0-9a-f]{40})/#\1#')
set_rev() {
  sed -i.bak -E "s#^([[:space:]]*libraryRevision: &libraryRevision )[^[:space:]]+#\1$1#" "$D/root/applicationset.yaml"
  rm "$D/root/applicationset.yaml.bak"
}

# The template follows the branch main: the guide's links keep their own commit.
run --check
t "following a branch: --check passes when every link names one commit" \
  eval '[ "$rc" = 0 ] && [ "$(links | wc -l | tr -d " ")" = 1 ] && grep -qF "guide links at $web/blob/$OLD/" <<<"$out"'
t "  ... and asks nothing of the library" eval '[ ! -e "$T/ls-remote.log" ]'

f="$D/docs/install/01-before-you-start.md"; cp "$f" "$T/keep"
echo "[old install guide]($web/blob/4444444444444444444444444444444444444444/docs/install/README.md)" >> "$f"
run --check
t "  ... a link into the library's own docs/install/ doesn't count" eval '[ "$rc" = 0 ]'
cp "$T/keep" "$f"
python3 -c 'import sys; p, o = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(o, "2" * 40, 1))' "$f" "$OLD"
run --check
t "  ... fails when the links name two commits" eval '[ "$rc" = 1 ] && grep -q "two or more commits" <<<"$out"'
cp "$T/keep" "$f"

run
t "following a branch, no REVISION: links move to the branch's commit now" \
  eval '[ "$rc" = 0 ] && [ "$(links)" = "ai-grid-cluster-gitops/blob/$MAIN/" ] && grep -q "refs/heads/main" "$T/ls-remote.log"'
t "  ... libraryRevision stays main" eval 'grep -q "libraryRevision: &libraryRevision main$" "$D/root/applicationset.yaml"'

run "$OLD"
t "a full SHA: links move to it" eval '[ "$rc" = 0 ] && [ "$(links)" = "ai-grid-cluster-gitops/blob/$OLD/" ]'

run no-such-branch
t "a revision the library doesn't have: stops, links unchanged" \
  eval '[ "$rc" = 1 ] && grep -q "no-such-branch" <<<"$out" && [ "$(links)" = "ai-grid-cluster-gitops/blob/$OLD/" ]'

# A deployment that pins a commit: its guide links follow the pin, as before.
P=3333333333333333333333333333333333333333
set_rev "$P"
run --check
t "pinned at a SHA: --check fails while the links name another commit" eval '[ "$rc" = 1 ] && grep -q "not at $web/blob/$P/" <<<"$out"'
run
t "  ... no REVISION: links move to the pin" eval '[ "$rc" = 0 ] && [ "$(links)" = "ai-grid-cluster-gitops/blob/$P/" ]'
run --check
t "  ... then --check passes" eval '[ "$rc" = 0 ]'

echo "sync-guide-pin tests: $((total-fails)) ok, $fails failed"; exit "$fails"
