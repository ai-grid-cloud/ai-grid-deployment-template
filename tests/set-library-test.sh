#!/usr/bin/env bash
# Tests for scripts/set-library.sh against a local bare repository standing in
# for the library, named in a copy of root/kustomization.yaml.
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

# The library: a first commit (the old pin, tagged v1 with an annotated tag),
# a branch one commit ahead, and a branch whose name the root can't hold.
work="$T/lib-work"; mkdir -p "$work"; g -C "$work" init -q
echo one > "$work/f"; g -C "$work" add -A; g -C "$work" commit -qm one
old=$(g -C "$work" rev-parse HEAD); g -C "$work" tag -a -m v1 v1
g -C "$work" checkout -qb feat/next; echo two > "$work/f"; g -C "$work" commit -qam two
new=$(g -C "$work" rev-parse HEAD)
g -C "$work" branch 'odd@name'; for b in 1.0 0x1f 0o17 +0X1F 1e5 2.5E-3; do g -C "$work" branch -- "$b"; done
g clone -q --bare "$work" "$T/lib.git"

# The template's own default: it follows the library's main branch.
. "$SRC/scripts/library.sh"
t "the template's default libraryRevision is the branch main" eval '[ "$(library_pin "$SRC" libraryRevision)" = main ]'

# A deployment copy whose root names the bare library and pins the old commit.
D="$T/deploy"; mkdir -p "$D"; cp -R "$SRC/scripts" "$SRC/root" "$D/"
k="$D/root/applicationset.yaml"
pin_root() { # REVISION: a fresh copy of the real root, naming the bare library, at REVISION
  cp "$SRC/root/applicationset.yaml" "$k"
  sed -i.bak -E -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops\.git#file://$T/lib.git#g" \
    -e "s#^([[:space:]]*libraryRevision: &libraryRevision )[^[:space:]]+#\1$1#" "$k"; rm "$k.bak"
}
pin_root "$old"

run() { out=$("$D/scripts/set-library.sh" "$@" 2>&1) && rc=0 || rc=$?; }
count() { grep -o -- "$1" "$k" | wc -l | tr -d ' '; }
comments() { grep -c '^ *#' "$k"; }
renders() { # REVISION: the root still renders, and every generator reads the library at REVISION
  local r="$T/render"
  rm -rf "$r"; mkdir -p "$r"; cp -R "$D/root" "$r/"
  printf '%s\n' deploymentRepoURL=https://git.example.com/d.git deploymentRevision=main \
    catalogRepoURL=https://git.example.com/c.git catalogRevision=main keycloakOverlay=core hubCertManager=library > "$r/root/inputs.env"
  oc kustomize "$r/root" > "$r/out.yaml" 2>&1 || { out=$(cat "$r/out.yaml"); return 1; }
  KUBECONFIG=/dev/null oc label --local -f "$r/out.yaml" ai-grid.dev/read=true -o json |
    jq -s '[.[] | if .kind == "List" then .items[] else . end | select(.kind == "ApplicationSet")][0]' > "$r/as.json"
  jq -e --arg s "$1" '.spec.generators[0].git.revision == $s and .spec.generators[1].matrix.generators[0].git.revision == $s
      and .spec.generators[0].git.values.libraryRevision == $s and .spec.generators[2].git.values.libraryRevision == $s' \
    "$r/as.json" >/dev/null || { out="generator revisions: $(jq -c '[.spec.generators[0].git.revision, .spec.generators[1].matrix.generators[0].git.revision]' "$r/as.json")"; return 1; }
}

c0=$(comments)
run feat/next
t "branch: writes the branch name, not its SHA, in the one place" \
  eval '[ "$rc" = 0 ] && [ "$(count "$new")" = 0 ] && [ "$(count "$old")" = 0 ] && grep -qF "following file://$T/lib.git branch feat/next (now at $new)" <<<"$out"'
t "  ... keeps the anchor and every comment, and the root renders following it" \
  eval 'grep -q "libraryRevision: &libraryRevision feat/next\$" "$k" && [ "$(comments)" = "$c0" ] && renders feat/next'

sum=$(cksum < "$k")
run feat/next
t "same branch: already following" eval '[ "$rc" = 0 ] && grep -q "already following" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

run "$new"
t "full SHA: pins it" \
  eval '[ "$rc" = 0 ] && [ "$(count "$new")" = 1 ] && grep -qF "pinned file://$T/lib.git at $new ($new)" <<<"$out" && renders "$new"'

sum=$(cksum < "$k")
run "$new"
t "same SHA: already pinned" eval '[ "$rc" = 0 ] && grep -q "already pinned" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

run v1
t "tag: pins its commit's SHA" \
  eval '[ "$rc" = 0 ] && [ "$(count "$old")" = 1 ] && ! grep -q "libraryRevision: &libraryRevision v1" "$k" && grep -qF "pinned file://$T/lib.git at $old (v1)" <<<"$out" && renders "$old"'

run main
t "from a SHA back to a branch: writes main" eval '[ "$rc" = 0 ] && grep -q "libraryRevision: &libraryRevision main\$" "$k" && [ "$(count "$old")" = 0 ] && renders main'

sum=$(cksum < "$k")
run 'odd@name'
t "a branch name the root can't hold: stops, says to pin a commit" \
  eval '[ "$rc" = 1 ] && grep -q "pin a commit" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

sum=$(cksum < "$k")
for b in 1.0 0x1f 0o17 +0X1F 1e5 2.5E-3; do
  run "$b"
  t "a branch name YAML reads as a number ($b): stops" eval '[ "$rc" = 1 ] && grep -q "pin a commit" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'
done

run no/such-branch
t "unknown revision: stops" eval '[ "$rc" = 1 ] && grep -q "no/such-branch" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

run "${new:0:7}"
t "short SHA: asks for a full 40-character SHA" eval '[ "$rc" = 1 ] && grep -q "use a full 40-character SHA" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

sed -i.bak -E "s#^([[:space:]]*libraryRevision: &libraryRevision )[^[:space:]]+#\1#" "$k"; rm "$k.bak"; sum=$(cksum < "$k")
run feat/next
t "no libraryRevision value: stops, file unchanged" eval '[ "$rc" = 1 ] && grep -q "libraryRevision" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

echo "set-library tests: $((total-fails)) ok, $fails failed"; exit "$fails"
