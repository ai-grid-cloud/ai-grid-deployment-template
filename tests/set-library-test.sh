#!/usr/bin/env bash
# Tests for scripts/set-library.sh against a local bare repository standing in
# for the library, named in a copy of root/kustomization.yaml.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
sed -i.bak -E -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops\.git#file://$T/lib.git#g" \
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
  eval '[ "$rc" = 0 ] && [ "$(count "$new")" = 3 ] && [ "$(count "$old")" = 0 ] && grep -qF "pinned file://$T/lib.git at $new (feat/next)" <<<"$out"'
t "  ... the remote base, the generator revision and values.libraryRevision" \
  eval 'grep -q "//bootstrap/hub?ref=$new\$" "$k" && grep -q "path: /spec/generators/0/git/revision, value: &libraryRevision $new }" "$k" && grep -q "libraryRevision: $new\$" "$k"'
t "  ... keeps every comment and still parses as YAML" eval '[ "$(comments)" = "$c0" ] && yaml_ok'

sum=$(cksum < "$k")
run feat/next
t "same pin: already pinned" eval '[ "$rc" = 0 ] && grep -q "already pinned" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

# The root pins the library through YAML anchors: generator 0's replace ops
# carry &libraryRepoURL and &libraryRevision, and the ODF generator aliases them.
renders() { # render a copy of $k with the remote base pointed at a local library
  local r="$T/render" lib="$T/real-lib" pin rel
  if [ ! -d "$lib" ]; then
    pin=$(sed -n -E 's#^[[:space:]]*- [^ ]+//bootstrap/hub\?ref=([0-9a-f]{40})$#\1#p' "$SRC/root/kustomization.yaml")
    mkdir -p "$lib"; git -C "${LIBRARY:-$("$SRC/scripts/library.sh" "$SRC")}" archive "$pin" | tar -x -C "$lib"
  fi
  rm -rf "$r"; mkdir -p "$r"; cp -R "$D/root" "$r/"
  rel=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$lib/bootstrap/hub" "$r/root")
  sed -i.bak -E "s#^  - [^ ]+//bootstrap/hub\?ref=[0-9a-f]+#  - $rel#" "$r/root/kustomization.yaml"; rm "$r/root/kustomization.yaml.bak"
  printf '%s\n' deploymentRepoURL=https://git.example.com/d.git deploymentRevision=main \
    catalogRepoURL=https://git.example.com/c.git catalogRevision=main idpIssuerURL=https://idp.example.com/realms/t > "$r/root/inputs.env"
  oc kustomize "$r/root" > "$r/out.yaml" 2>&1 || { out=$(cat "$r/out.yaml"); return 1; }
  KUBECONFIG=/dev/null oc label --local -f "$r/out.yaml" ai-grid.dev/read=true -o json |
    jq -s '[.[] | if .kind == "List" then .items[] else . end | select(.kind == "ApplicationSet")][0]' > "$r/as.json"
  jq -e --arg s "$1" '.spec.generators[0].git.revision == $s and .spec.generators[1].matrix.generators[0].git.revision == $s' \
    "$r/as.json" >/dev/null || { out="generator revisions: $(jq -c '[.spec.generators[0].git.revision, .spec.generators[1].matrix.generators[0].git.revision]' "$r/as.json")"; return 1; }
}
anchored_root() { # anchored_root SHA: a fresh copy of the real root, naming the bare library, pinned at SHA
  cp "$SRC/root/kustomization.yaml" "$k"
  sed -i.bak -E -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops\.git#file://$T/lib.git#g" \
    -e "s#https://github.com/ai-grid-cloud/ai-grid-cluster-gitops//#file://$T/lib.git//#g" \
    -e "s/[0-9a-f]{40}/$1/g" "$k"; rm "$k.bak"
}
anchored_root "$old"
run feat/next
t "anchored root: pins the SHA, keeps the anchor, and the root still renders" \
  eval '[ "$rc" = 0 ] && grep -q "value: &libraryRevision $new }" "$k" && grep -q "value: &libraryRepoURL file://" "$k" && renders "$new"'
anchored_root "$new"; sum=$(cksum < "$k")
run feat/next
t "anchored root: already pinned" eval '[ "$rc" = 0 ] && grep -q "already pinned" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

sum=$(cksum < "$k")
run no/such-branch
t "unknown revision: stops" eval '[ "$rc" = 1 ] && grep -q "no/such-branch" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

run "${new:0:7}"
t "short SHA: asks for a full 40-character SHA" eval '[ "$rc" = 1 ] && grep -q "use a full 40-character SHA" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

sed -i.bak -E "s#file://$T/lib\.git//bootstrap#https://example.com/other/repo//bootstrap#" "$k"; rm "$k.bak"; sum=$(cksum < "$k")
run feat/next
t "remote base names another repository: stops and names both" \
  eval '[ "$rc" = 1 ] && grep -qF "https://example.com/other/repo" <<<"$out" && grep -qF "file://$T/lib.git" <<<"$out" && [ "$(cksum < "$k")" = "$sum" ]'

echo "set-library tests: $((total-fails)) ok, $fails failed"; exit "$fails"
