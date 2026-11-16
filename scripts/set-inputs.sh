#!/usr/bin/env bash
# Set the values that name your repositories (install guide, page 2), then check
# the repository:
#
#   root/inputs.env   deploymentRepoURL, deploymentRevision, catalogRepoURL,
#                     catalogRevision
#   hub/catalog/      the catalog repository and revision, from inputs.env
#
# deploymentRepoURL is this repository's origin, catalogRepoURL the argument;
# both revisions are main. root/inputs.env is yours: the template has none, and
# root/kustomization.yaml copies its values into the root. A value that's
# already set in it is left alone. hub/catalog/ always follows inputs.env: it's
# rewritten from it on every run. It reads no cluster.
#
# Usage: scripts/set-inputs.sh CATALOG_REPO_URL
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
[ $# -eq 1 ] || { echo "usage: set-inputs.sh CATALOG_REPO_URL" >&2; exit 2; }

https_url() { # a git remote URL -> https://HOST/OWNER/REPO.git, no credentials
  local u=${1%/}
  case "$u" in
    git@*:*) u="${u#git@}"; u="https://${u/://}" ;;
    ssh://git@*) u="https://${u#ssh://git@}" ;;
  esac
  u=$(sed -E 's#^https://[^@/]+@#https://#' <<<"$u")
  [[ "$u" =~ ^https://[^/]+/.+ ]] || { echo "error: $1 isn't a repository URL" >&2; return 1; }
  [ "${u%.git}" = "$u" ] && u="$u.git"
  echo "$u"
}

catalog=$(https_url "$1")
origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || { echo "error: this repository has no origin remote" >&2; exit 1; }
deployment=$(https_url "$origin")

DIR=$dir python3 - "$deployment" "$catalog" <<'PY'
import os, re, sys
deployment, catalog = sys.argv[1:]
d = os.environ["DIR"]

# root/inputs.env: keep each value that's set, add the rest.
path = "root/inputs.env"
f = os.path.join(d, path)
want = [("deploymentRepoURL", deployment), ("deploymentRevision", "main"), ("catalogRepoURL", catalog),
        ("catalogRevision", "main")]
lines = open(f).read().splitlines() if os.path.exists(f) else [
    "# Your deployment's inputs (install guide, page 2), written by scripts/set-inputs.sh.",
    "# root/kustomization.yaml copies them into the root. This file is yours: the",
    "# template has none.",
]
have = {}
for i, line in enumerate(lines):
    if "=" in line and not line.lstrip().startswith("#"):
        have[line.split("=", 1)[0].strip()] = i
for name, value in want:
    i = have.get(name)
    old = lines[i].split("=", 1)[1].strip() if i is not None else ""
    if old and not old.startswith("REQUIRED-"):
        print(f"kept     {path}: {name} is already set")
        continue
    if i is None:
        lines.append(f"{name}={value}")
    else:
        lines[i] = f"{name}={value}"
    print(f"set      {path}: {name} = {value}")
tmp = f + ".tmp"
open(tmp, "w").write("\n".join(lines) + "\n")
os.replace(tmp, f)

# hub/catalog/: the catalog repository and revision inputs.env now names.
final = {}
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        final[k.strip()] = v.strip()
url, rev = final.get("catalogRepoURL", ""), final.get("catalogRevision", "")
cdir = os.path.join(d, "hub", "catalog")
for name in sorted(os.listdir(cdir)) if url and rev else []:
    if not name.endswith(".yaml"):
        continue
    f = os.path.join(cdir, name)
    text = open(f).read()
    new = re.sub(r"(?m)^(\s*repoURL:[ \t]*)\S+$", lambda m: m.group(1) + url, text)
    new = re.sub(r"(?m)^(\s*(?:target)?[rR]evision:[ \t]*)\S+$", lambda m: m.group(1) + rev, new)
    new = re.sub(r"(?m)^(\s*sourceRepos:\n\s*-[ \t]*)\S+$", lambda m: m.group(1) + url, new)
    if new != text:
        tmp = f + ".tmp"
        open(tmp, "w").write(new)
        os.replace(tmp, f)
        print(f"set      hub/catalog/{name}: {url} at {rev}")
    else:
        print(f"kept     hub/catalog/{name}: already {url} at {rev}")
PY
"$here/check-deployment.sh" "$dir"
