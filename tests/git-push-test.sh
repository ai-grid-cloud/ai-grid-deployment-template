#!/usr/bin/env bash
# Tests for scripts/git-push.sh against a local bare repository as origin and a
# token file holding a sentinel value.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SENTINEL='ghp_SENTINEL'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c init.defaultBranch=main -c core.hooksPath=/dev/null "$@"; }
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

# A git wrapper on PATH that logs every argv, so a test can look for the
# token. A local origin never asks for a password, so on push the wrapper asks
# $GIT_ASKPASS itself, as git would for https, and keeps the answer and the
# helper's path and mode for the checks.
REAL_GIT=$(command -v git)
mkdir -p "$T/bin"
cat > "$T/bin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
if [[ " \$* " == *" push "* ]] && [ -n "\${GIT_ASKPASS:-}" ]; then
  "\$GIT_ASKPASS" "Password for 'https://x-access-token@github.com': " > "$T/askpass.out"
  printf '%s %s\n' "\$GIT_ASKPASS" "\$(stat -f %Lp "\$GIT_ASKPASS" 2>/dev/null || stat -c %a "\$GIT_ASKPASS")" > "$T/askpass.path"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/bin/git"; : > "$T/argv.log"

# origin, and the deployment repository cloned from it with the token file.
seed="$T/seed"; mkdir -p "$seed"; cp -R "$SRC/scripts" "$seed/"; echo v1 > "$seed/site.yaml"
g -C "$seed" init -q && g -C "$seed" add -A && g -C "$seed" commit -qm v1
g clone -q --bare "$seed" "$T/origin.git"
D="$T/deploy"; g clone -q "$T/origin.git" "$D"; g -C "$D" config core.hooksPath /dev/null
mkdir -p "$D/.config"; printf '%s\n' "$SENTINEL" > "$D/.config/deployment-token"

run() { # MESSAGE PATH...: runs git-push.sh in $D; sets rc and out
  out=$(cd "$D" && PATH="$T/bin:$PATH" DEPLOYMENT_TOKEN_FILE=.config/deployment-token \
    scripts/git-push.sh "$@" 2>&1) && rc=0 || rc=$?
  all_out+="$out"$'\n'
}
all_out=""

echo v1b > "$D/site.yaml"
run "before any site" site.yaml sites
t "missing path: commits and pushes the paths that exist" \
  eval '[ "$rc" = 0 ] && [ "$(g -C "$T/origin.git" log -1 --format=%s main)" = "before any site" ] && [ "$(g -C "$T/origin.git" show main:site.yaml)" = v1b ]'

echo v2 > "$D/site.yaml"; mkdir -p "$D/sites"; echo new > "$D/sites/b.yaml"
run "add site b" site.yaml sites
t "changes: commits and pushes" \
  eval '[ "$rc" = 0 ] && [ "$(g -C "$T/origin.git" log -1 --format=%s main)" = "add site b" ] && [ "$(g -C "$T/origin.git" show main:sites/b.yaml)" = new ]'

run "again" site.yaml sites
t "nothing to push" eval '[ "$rc" = 0 ] && grep -qx "nothing to push" <<<"$out"'

# Someone else moves the remote first.
other="$T/other"; g clone -q "$T/origin.git" "$other"; echo theirs > "$other/theirs"
g -C "$other" add -A && g -C "$other" commit -qm theirs && g -C "$other" push -q origin main
echo v3 > "$D/site.yaml"
run "change site" site.yaml
t "push rejected: stops and names the remote" \
  eval '[ "$rc" = 1 ] && grep -q origin <<<"$out" && grep -q rejected <<<"$out" && grep -qF "pull --rebase origin main, then run make install again" <<<"$out" && [ "$(g -C "$T/origin.git" log -1 --format=%s main)" = theirs ]'

t "token never in argv or output" \
  eval '[ -s "$T/argv.log" ] && ! grep -qF "$SENTINEL" "$T/argv.log" && ! grep -qF "$SENTINEL" <<<"$all_out"'
read -r helper mode < "$T/askpass.path" || true
t "  ... GIT_ASKPASS gives the token from the file, mode 700, removed after" \
  eval '[ "$(cat "$T/askpass.out")" = "$SENTINEL" ] && [ "$mode" = 700 ] && [ ! -e "$helper" ] && ! grep -qF "$SENTINEL" "$helper" 2>/dev/null'

echo "git-push tests: $((total-fails)) ok, $fails failed"; exit "$fails"
