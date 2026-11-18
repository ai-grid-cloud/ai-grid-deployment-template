#!/usr/bin/env bash
# Tests for scripts/check-public-repos.sh: the hub reads the deployment and
# catalog repositories with no login. A stub git answers ls-remote from files
# (no network) and logs the arguments, environment and directory it got, so the
# tests can tell that nothing of the caller's (a credential helper, git config,
# askpass, HOME and its .netrc) reached it.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../scripts/check-public-repos.sh"
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
REAL_GIT=$(command -v git)
total=0 fails=0
FAKE="fake-cred-$RANDOM$RANDOM"   # built at runtime; must never reach git

# The stub git: ls-remote URL logs to $S/log, sleeps $S/sleep seconds when that
# file exists, and fails with $S/err.REPO (REPO: the URL's last part, no .git)
# when that file exists. Anything else goes to the real git. $S is baked in,
# because the script runs git with a clean environment.
S="$T/stub"; mkdir -p "$S" "$T/bin"
cat > "$T/bin/git" <<STUB
#!/bin/bash
case " \$* " in
  *" ls-remote "*)
    url=\${!#}; repo=\${url##*/}; repo=\${repo%.git}
    { echo "ARGS \$*"; echo "PWD \$PWD"; env | sed 's/^/ENV /'; } >> "$S/log"
    [ ! -f "$S/sleep" ] || sleep "\$(cat "$S/sleep")"
    [ ! -f "$S/err.\$repo" ] || { cat "$S/err.\$repo" >&2; exit 128; }
    printf '%040d\trefs/heads/main\n' 0 ;;
  *) exec "$REAL_GIT" "\$@" ;;
esac
STUB
chmod +x "$T/bin/git"

D="$T/deploy"; mkdir -p "$D/root"
inputs() { printf '%s\n' "deploymentRepoURL=$1" "catalogRepoURL=$2" > "$D/root/inputs.env"; }
run() { # [VAR=value ...]: runs the script on $D ($FLAGS before it) with the stub git first on PATH; sets rc and out
  rm -f "$S/log"
  out=$(env PATH="$T/bin:$PATH" HOME="$T/home" "$@" "$SCRIPT" ${FLAGS:-} "$D" 2>&1) && rc=0 || rc=$?
}
t() { # name condition...
  local name=$1; shift; total=$((total+1))
  if "$@"; then echo "   ok   $name"; else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}
mkdir -p "$T/home"; printf 'machine github.com login stub password %s\n' "$FAKE" > "$T/home/.netrc"

DEP=https://github.com/acme/deploy.git CAT=https://github.com/acme/catalog.git
inputs "$DEP" "$CAT"
run GIT_CONFIG_PARAMETERS="'credential.helper'='!echo password=$FAKE'" GIT_ASKPASS="$T/askpass" \
  GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_TERMINAL_PROMPT=1 GH_TOKEN="$FAKE"
t "both public: ok, exit 0" eval '[ "$rc" = 0 ] &&
  grep -qE "^ok +deployment repository +https://github.com/acme/deploy.git: readable with no login$" <<<"$out" &&
  grep -qE "^ok +catalog repository +https://github.com/acme/catalog.git: readable with no login$" <<<"$out"'
t "  ... git ls-remote --heads of each URL, nothing else" eval '[ "$(grep -c "^ARGS " "$S/log")" = 2 ] &&
  grep -qx "ARGS -c credential.helper= -c core.askPass=.*false ls-remote --heads -- $DEP" "$S/log" &&
  grep -qx "ARGS -c credential.helper= -c core.askPass=.*false ls-remote --heads -- $CAT" "$S/log"'
t "  ... no prompt, askpass that fails, no global or system git config" eval '
  grep -qx "ENV GIT_TERMINAL_PROMPT=0" "$S/log" && grep -qxE "ENV GIT_ASKPASS=/.*/false" "$S/log" &&
  grep -qxE "ENV SSH_ASKPASS=/.*/false" "$S/log" && grep -qx "ENV GIT_CONFIG_GLOBAL=/dev/null" "$S/log" &&
  grep -qx "ENV GIT_CONFIG_NOSYSTEM=1" "$S/log"'
t "  ... none of the caller's credentials, config or HOME reach git" eval '! grep -qF "$FAKE" "$S/log" &&
  ! grep -q "^ENV GIT_CONFIG_PARAMETERS=" "$S/log" && ! grep -q "^ENV GH_TOKEN=" "$S/log" &&
  ! grep -qx "ENV HOME=$T/home" "$S/log" && ! grep -qF "$T/askpass" "$S/log"'
t "  ... no repository to read config from" eval 'grep -qx "ENV GIT_DIR=/nonexistent" "$S/log" && grep -qE "^ENV GIT_CEILING_DIRECTORIES=/" "$S/log"'
t "  ... run from an empty directory, not the repository" eval '! grep -qx "PWD $D" "$S/log" &&
  [ "$(grep "^PWD " "$S/log" | sort -u | wc -l | tr -d " ")" = 2 ] && ! grep -q "^PWD $D" "$S/log"'
run HTTPS_PROXY=http://proxy.example.com:3128
t "  ... a proxy passes through" grep -qx "ENV HTTPS_PROXY=http://proxy.example.com:3128" "$S/log"
# Your git config's proxy and CA settings carry no login: they pass as -c; its credential settings don't.
printf '[http]\n\tproxy = http://proxy.example.com:3128\n\tsslCAInfo = %s/ca.pem\n\textraHeader = Authorization: Basic %s\n[credential]\n\thelper = store\n' "$T" "$FAKE" > "$T/gitconfig"
run GIT_CONFIG_GLOBAL="$T/gitconfig"
t "  ... git config's http.proxy and http.sslCAInfo pass as -c, nothing else" eval '[ "$rc" = 0 ] &&
  grep -qE "^ARGS .* -c http.proxy=http://proxy.example.com:3128 -c http.sslCAInfo=$T/ca.pem ls-remote --heads -- $DEP$" "$S/log" &&
  ! grep -qF "$FAKE" "$S/log" && ! grep -q "store" "$S/log"'
# The watchdog leaves no sleep behind (a timeout no other test uses, to find its sleep).
run PUBLIC_REPO_TIMEOUT=37
t "  ... no sleep left running after a check" eval '[ "$rc" = 0 ] && ! pgrep -f "^sleep 37$" >/dev/null'

printf '%s\n' "remote: Repository not found." "fatal: Authentication failed for 'https://github.com/acme/catalog.git/'" > "$S/err.catalog"
run
t "private or missing catalog: FAIL, make it public, exit 1" eval '[ "$rc" = 1 ] &&
  grep -qE "^ok +deployment repository" <<<"$out" &&
  grep -qF "FAIL     catalog repository     https://github.com/acme/catalog.git is private or doesn'"'"'t exist: the hub reads this repository without a login: make it public (gh repo edit acme/catalog --visibility public --accept-visibility-change-consequences); private repositories aren'"'"'t supported (Authentication failed for" <<<"$out"'
FLAGS=--network-warn run
t "  ... still a FAIL with --network-warn" eval '[ "$rc" = 1 ] && grep -qE "^FAIL +catalog repository +.*is private or doesn.t exist" <<<"$out"'
rm "$S/err.catalog"
echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" > "$S/err.deploy"
run
t "GitHub's answer for a private repository with no prompt: the same FAIL" eval '[ "$rc" = 1 ] &&
  grep -qE "^FAIL +deployment repository +.*make it public \(gh repo edit acme/deploy --visibility public --accept-visibility-change-consequences\); private repositories aren.t supported" <<<"$out"'
rm "$S/err.deploy"
inputs https://git.example.com/acme/deploy.git "$CAT"
echo "fatal: repository 'https://git.example.com/acme/deploy.git/' not found" > "$S/err.deploy"
run
t "another host: make it public there, no gh command" eval '[ "$rc" = 1 ] &&
  grep -qE "^FAIL +deployment repository +.*make it public on git.example.com; private" <<<"$out" && ! grep -q "gh repo edit" <<<"$out"'
rm "$S/err.deploy"

inputs "$DEP" "$CAT"
echo "fatal: unable to access 'https://github.com/acme/deploy.git/': Could not resolve host: github.com" > "$S/err.deploy"
run
t "network error: a distinct FAIL, not make it public" eval '[ "$rc" = 1 ] &&
  grep -qE "^FAIL +deployment repository +https://github.com/acme/deploy.git: can.t reach github.com \(unable to access .*Could not resolve host: github.com\); a network error, not a login one" <<<"$out" &&
  ! grep -q "make it public" <<<"$out"'
FLAGS=--network-warn run
t "  ... a WARN with --network-warn, exit 0" eval '[ "$rc" = 0 ] &&
  grep -qE "^WARN +deployment repository +.*a network error, not a login one" <<<"$out" && ! grep -q "^FAIL" <<<"$out"'
rm "$S/err.deploy"
echo "fatal: unable to access 'https://github.com/acme/deploy.git/': The requested URL returned error: 429" > "$S/err.deploy"
run
t "429: rate-limited, not private" eval '[ "$rc" = 1 ] && grep -qE "^FAIL +deployment repository +.*github.com is limiting requests" <<<"$out" && ! grep -q "make it public" <<<"$out"'
echo "fatal: unable to access 'https://github.com/acme/deploy.git/': The requested URL returned error: 407" > "$S/err.deploy"
FLAGS=--network-warn run
t "407: the proxy's login, a WARN with --network-warn" eval '[ "$rc" = 0 ] && grep -qE "^WARN +deployment repository +.*your proxy wants a login" <<<"$out"'
rm "$S/err.deploy"
echo 3 > "$S/sleep"
run PUBLIC_REPO_TIMEOUT=1
t "no answer in time: a timeout FAIL, not make it public" eval '[ "$rc" = 1 ] &&
  grep -qE "^FAIL +deployment repository +.*no answer from github.com in 1s; a network error, not a login one" <<<"$out" &&
  ! grep -q "make it public" <<<"$out"'
FLAGS=--network-warn run PUBLIC_REPO_TIMEOUT=1
t "  ... a WARN with --network-warn" eval '[ "$rc" = 0 ] && grep -qE "^WARN +deployment repository +.*no answer from github.com in 1s" <<<"$out"'
rm "$S/sleep"

inputs REQUIRED-deploymentRepoURL REQUIRED-catalogRepoURL
run
t "placeholders: skipped, no git call, exit 0" eval '[ "$rc" = 0 ] && [ ! -f "$S/log" ] &&
  grep -qE "^skipped +deployment repository +deploymentRepoURL in root/inputs.env is still REQUIRED-deploymentRepoURL" <<<"$out" &&
  grep -qE "^skipped +catalog repository +catalogRepoURL in root/inputs.env is still REQUIRED-catalogRepoURL" <<<"$out"'
inputs "https://stub:$FAKE@github.com/acme/deploy.git" "$CAT"
run
t "a login in the URL: FAIL, never printed, no git call for it" eval '[ "$rc" = 1 ] &&
  grep -qE "^FAIL +deployment repository +https://github.com/acme/deploy.git \(deploymentRepoURL in root/inputs.env\): remove the login from the URL: the hub reads it with no login$" <<<"$out" &&
  ! grep -qF "$FAKE" <<<"$out" && ! grep -qF "$FAKE" "$S/log" && [ "$(grep -c "^ARGS " "$S/log")" = 1 ]'
inputs git@github.com:acme/deploy.git ssh://git@github.com/acme/catalog.git
run
t "SSH URLs: FAIL, the hub has no SSH key; no git call" eval '[ "$rc" = 1 ] && [ ! -f "$S/log" ] &&
  [ "$(grep -c "has no SSH key; set an https:// URL" <<<"$out")" = 2 ]'

# No inputs.env yet (make prereqs before make inputs): origin as https://, and CATALOG_REPO_URL.
rm "$D/root/inputs.env"; "$REAL_GIT" -C "$D" init -q; "$REAL_GIT" -C "$D" remote add origin git@github.com:acme/deploy.git
run CATALOG_REPO_URL="$CAT"
t "no inputs.env: origin's https:// form and CATALOG_REPO_URL" eval '[ "$rc" = 0 ] &&
  grep -qE "^ok +deployment repository +$DEP: readable" <<<"$out" && grep -qE "^ok +catalog repository +$CAT: readable" <<<"$out"'
run CATALOG_REPO_URL=git@github.com:acme/catalog
t "CATALOG_REPO_URL as an SSH URL: checked as its https:// form, as make inputs writes it" eval '[ "$rc" = 0 ] &&
  grep -qE "^ok +catalog repository +$CAT: readable" <<<"$out"'
run CATALOG_REPO_URL=
t "no catalog yet: skipped" eval '[ "$rc" = 0 ] && grep -qE "^skipped +catalog repository +no URL yet: run make inputs" <<<"$out"'
out=$(env PATH="$T/bin:$PATH" CATALOG_REPO_URL="$CAT" "$SCRIPT" --tsv "$D" 2>&1) && rc=0 || rc=$?
t "--tsv: three tab-separated fields" eval '[ "$rc" = 0 ] && [ "$(head -n1 <<<"$out")" = "$(printf "ok\tdeployment repository\t%s: readable with no login" "$DEP")" ]'

echo "check-public-repos tests: $((total-fails)) ok, $fails failed"; exit "$fails"
