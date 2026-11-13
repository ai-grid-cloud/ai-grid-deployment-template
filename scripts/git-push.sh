#!/usr/bin/env bash
# Commit the given paths of this deployment repository, when they changed, and
# push HEAD to origin, with no prompt.
#
# The token comes from the file named by $DEPLOYMENT_TOKEN_FILE (default
# .config/deployment-token, relative to this repository), a GitHub token that
# can write this repository. git reads it through a temporary GIT_ASKPASS
# helper (mode 700) that reads the file when git asks, so the token is never
# on a command line, in the helper, or in the output. The helper is removed on
# exit. Credential helpers you have configured are skipped for this push.
#
# Prints "nothing to push" when the paths have no changes and origin already
# has HEAD. On a rejected push (origin moved, or the token can't write) it
# exits 1 with git's reason; it never retries.
#
# Usage: scripts/git-push.sh MESSAGE PATH...
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
[ $# -ge 2 ] && [ -n "$1" ] || { echo "usage: git-push.sh MESSAGE PATH..." >&2; exit 2; }
msg=$1; shift
cd "$dir"
export GIT_TERMINAL_PROMPT=0

token_file=${DEPLOYMENT_TOKEN_FILE:-.config/deployment-token}
case "$token_file" in /*) ;; *) token_file="$dir/$token_file" ;; esac
[ -r "$token_file" ] || { echo "error: no token file $token_file: put a token that can push to origin there" >&2; exit 1; }
branch=$(git symbolic-ref --quiet --short HEAD) || { echo "error: HEAD isn't on a branch" >&2; exit 1; }

askpass=$(mktemp "${TMPDIR:-/tmp}/git-askpass.XXXXXX"); trap 'rm -f "$askpass"' EXIT
chmod 700 "$askpass"
# The helper holds the file's path, never its contents.
printf '#!/bin/bash\ncase "$1" in Username*) echo x-access-token ;; *) head -n1 %q ;; esac\n' "$token_file" > "$askpass"
export GIT_ASKPASS=$askpass
gitc() { git -c credential.helper= "$@"; }

if [ -n "$(git status --porcelain -- "$@")" ]; then
  git add -- "$@"
  git commit -q -m "$msg" -- "$@"
  echo "committed $(git rev-parse --short HEAD): $msg"
fi

remote=$(gitc ls-remote origin "refs/heads/$branch" 2>&1) ||
  { echo "error: can't read origin ($(git remote get-url origin | sed -E 's#://[^@/]+@#://#')): $remote" >&2; exit 1; }
if [ "${remote%%[[:space:]]*}" = "$(git rev-parse HEAD)" ]; then echo "nothing to push"; exit 0; fi

if ! out=$(gitc push --porcelain origin "HEAD:refs/heads/$branch" 2>&1); then
  echo "$out" >&2
  echo "error: push to origin ($branch) was rejected; git's reason is above. Nothing was retried." >&2
  exit 1
fi
echo "pushed $(git rev-parse --short HEAD) to origin $branch"
