#!/usr/bin/env python3
"""Report which AI Grid install prerequisites you have. Never blocks; changes nothing on a cluster.

Usage: scripts/prereqs.py [--library DIR] [--deployment DIR]
                          [--quay-auth-file FILE] [--catalog-token-file FILE]

Runs from your deployment repository; the library is .library/, which make prereqs fetches
at your library revision: the tip of the branch you follow, or the commit you pin
(scripts/library.sh).

The clusters come from the deployment's clusters.yaml, each with its login in
.config/NAME/kubeconfig. LIBRARY sets the library checkout.

Without --quay-auth-file and --catalog-token-file, it checks the secrets make
install uses, as scripts/clusters.sh deployment_load finds them (clusters.sh
--resolve): AI_GRID_* values, then QUAY_AUTH_FILE and CATALOG_TOKEN_FILE, then
quay:, catalog.token and deployment.token in .config/clusters.yaml, then .config/quay-auth.json and
.config/catalog-token. That refreshes .config/generated/ from .config/clusters.yaml,
the only thing it writes. Page by page (no .config/clusters.yaml and no catalog in
clusters.yaml or CATALOG_REPO_URL), the environment variables apply, else
QUAY_AUTH_FILE is the first of ~/.config/containers/auth.json and
$XDG_RUNTIME_DIR/containers/auth.json that exists, and CATALOG_TOKEN_FILE is
~/.ai-grid/catalog-token if it exists. A check whose input you haven't set prints
"skipped". The deployment and catalog repositories must be public, because the
hub reads them with no login: scripts/check-public-repos.sh checks each with an
anonymous git ls-remote. Every line is: status, name, detail. Statuses: ok, MISSING,
OLD, FAIL, skipped. Cluster checks are read-only (get, whoami, auth can-i).
The registry check runs "oc image info" with your auth file; it never prints a
credential. The exit code is always 0.
"""
import argparse
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys

# This script lives in your deployment repository; scripts/library.sh fetches the library into .library/.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.environ.get("LIBRARY") or os.path.join(REPO, ".library")
MIN_OPENSHIFT = (4, 21)
OC_TIMEOUT = "--request-timeout=10s"

# name, version command (None: no cheap version), what it's used for
TOOLS = [
    ("oc", ["oc", "version", "--client"], "the OpenShift CLI, which also renders your root (oc kustomize): every page"),
    ("kubectl", ["kubectl", "version", "--client"], "comes with oc: every page"),
    ("git", ["git", "--version"], "clones and pushes your repositories"),
    ("jq", ["jq", "--version"], "used by the setup scripts and in first use"),
    ("curl", ["curl", "--version"], "used by the setup scripts and in first use"),
    ("openssl", ["openssl", "version"], "used by the setup scripts and in first use"),
    ("base64", None, "used by the setup scripts and in first use"),
    ("python3", ["python3", "--version"], "reads cluster state in the setup scripts"),
    ("clusteradm", ["clusteradm", "version"], "imports the site into ACM"),
    ("make", ["make", "--version"], "runs make prereqs"),
]

results = []
secrets = []  # values to scrub from anything printed


def report(status, name, detail=""):
    for s in secrets:
        detail = detail.replace(s, "[redacted]")
    results.append(status)
    print(f"{status:<8} {name:<32} {detail}".rstrip())


def section(title):
    print(f"\n{title}")


def run(cmd, timeout=20):
    """Run cmd; return (rc, stdout, stderr). Never raises; a timeout is rc 124."""
    env = dict(os.environ)
    if cmd[0] in ("clusteradm",):
        env["KUBECONFIG"] = os.devnull  # version only; never reach a cluster
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except OSError as e:
        return 127, "", str(e)


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return scrub(line.strip())[:160]
    return ""


def scrub(text):
    for s in secrets:
        text = text.replace(s, "[redacted]")
    # Long base64-like runs could be credentials; image digests stay readable.
    return re.sub(r"(?<!sha256:)[A-Za-z0-9+/=_-]{40,}", "[redacted]", text)


def version_of(text):
    m = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text)
    return m


def check_tools():
    section("Tools")
    for name, cmd, used_for in TOOLS:
        path = shutil.which(name)
        if not path:
            report("MISSING", name, used_for)
            continue
        if not cmd:
            report("ok", name, path)
            continue
        rc, out, err = run(cmd, timeout=5)
        m = version_of(out + err)
        if m:
            report("ok", name, m.group(0).lstrip("v"))
        else:
            report("ok", name, path)


def check_library(deployment):
    section("Library checkout")
    if not deployment:
        report("skipped", "library at your revision", "pass --deployment DIR (make prereqs does)")
        return
    k = os.path.join(deployment, "root", "applicationset.yaml")
    try:
        text = open(k).read()
    except OSError:
        report("FAIL", "library at your revision", f"can't read {k}")
        return
    # The value: a full commit SHA (a pin) or a branch the hub follows; not a
    # YAML anchor (&name) or alias (*name).
    m = re.search(r"^\s*libraryRevision:[ \t]*(?:&[\w-]+[ \t]+)?([^\s#&*][^\s#]*)", text, re.M)
    if not m:
        report("FAIL", "library at your revision", f"no libraryRevision in {k}")
        return
    pin = m.group(1)
    lib = os.path.relpath(LIB)
    if not os.path.exists(os.path.join(LIB, ".git")):
        report("FAIL", "library at your revision", f"no library checkout at {lib}: run scripts/library.sh")
        return
    rc, out, _ = run(["git", "-C", LIB, "rev-parse", "HEAD"], timeout=5)
    head = out.strip() if rc == 0 else ""
    if re.fullmatch(r"[0-9a-f]{40}", pin):
        if head == pin:
            report("ok", "library at your revision", pin[:12])
        else:
            report("FAIL", "library at your revision",
                   f"{lib} is at {head[:12] or 'unknown'}, not {pin[:12]}: git -C {lib} checkout -q {pin}")
        return
    # A branch: the checkout's origin/BRANCH (scripts/library.sh fetches it) or
    # its local BRANCH, as last fetched; this check never fetches.
    for ref in (f"refs/remotes/origin/{pin}", f"refs/heads/{pin}"):
        rc, out, _ = run(["git", "-C", LIB, "rev-parse", "-q", "--verify", ref + "^{commit}"], timeout=5)
        if head and rc == 0 and out.strip() == head:
            report("ok", "library at your revision", f"{pin} at {head[:12]}")
            return
    report("FAIL", "library at your revision",
           f"{lib} is at {head[:12] or 'unknown'}, not at the tip of {pin}: run scripts/library.sh")


def pinned_catalog_image():
    """quay.io/rhoai/...@sha256:... from apps/rhoai/nightly.yaml, or None."""
    try:
        text = open(os.path.join(LIB, "apps", "rhoai", "nightly.yaml")).read()
    except OSError:
        return None
    vals = {}
    for key in ("registry", "repository", "tag"):
        m = re.search(rf"^\s+{key}:\s*(\S+)", text, re.M)
        if m:
            vals[key] = m.group(1).strip("'\"")
    if not {"registry", "repository", "tag"} <= vals.keys():
        return None
    tag = vals["tag"]
    ref = tag[tag.index("@"):] if "@" in tag else ":" + tag
    return f"{vals['registry']}/{vals['repository']}{ref}"


HINTS = {  # the fix when make install's file is missing (scripts/clusters.sh secret_missing)
    "QUAY_AUTH_FILE": "set quay.username and quay.password in .config/clusters.yaml (make config creates it)",
    "CATALOG_TOKEN_FILE": "set catalog.token in .config/clusters.yaml (make config creates it)",
    "DEPLOYMENT_TOKEN_FILE": "set deployment.token in .config/clusters.yaml (make config creates it)",
}


def check_deployment_push(deployment, resolved):
    """How make install pushes this repository: with the optional deployment token, else with
    your own git login, which is checked with a dry-run push to origin, with no prompt. A dry run
    sends no objects and creates no branch; it pushes to a branch name of its own so a main that
    moved on doesn't read as a refusal."""
    section("Deployment push")
    path, source = resolved
    if path and os.path.isfile(path) and os.path.getsize(path):
        report("ok", "deployment push", "with the token from " + (from_value(source) or path))
        return
    if path:
        report("FAIL", "deployment push", f"{source or 'the token file'} names {path}, which is missing or empty")
        return
    os.environ["GIT_TERMINAL_PROMPT"] = "0"
    os.environ["GIT_SSH_COMMAND"] = os.environ.get("GIT_SSH_COMMAND", "ssh") + " -o BatchMode=yes"
    rc, _, err = run(["git", "-C", deployment, "push", "--dry-run", "--no-verify", "--quiet", "origin",
                      "HEAD:refs/heads/ai-grid-prereqs-push-check"])
    if rc == 0:
        report("ok", "deployment push", "no token: your git login can push to origin (dry run)")
    else:
        report("FAIL", "deployment push", f"no token, and your git login can't push to origin ({first_line(err)}); "
               "log in to GitHub (such as gh auth login), or " + HINTS["DEPLOYMENT_TOKEN_FILE"])


def check_public_repos(deployment, settings):
    """The hub's Argo CD reads the deployment and catalog repositories with no login, so each must be
    public: scripts/check-public-repos.sh runs an anonymous git ls-remote of each. Runs once there's
    something to check: root/inputs.env, or make install's settings (catalog.url)."""
    if settings is None and not os.path.isfile(os.path.join(deployment, "root", "inputs.env")):
        return
    section("Repositories the hub reads")
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/bin:/bin")
    catalog = (settings or {}).get("CATALOG_REPO_URL") or os.environ.get("CATALOG_REPO_URL", "")
    env["CATALOG_REPO_URL"] = catalog
    try:
        p = subprocess.run(["/bin/bash", os.path.join(REPO, "scripts", "check-public-repos.sh"), "--tsv", deployment],
                           capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        report("FAIL", "repositories the hub reads", f"can't run scripts/check-public-repos.sh: {type(e).__name__}")
        return
    rows = [line.split("\t", 2) for line in p.stdout.splitlines() if line.count("\t") >= 2]
    for status, name, detail in rows:
        report(status, name, detail)  # URLs, which scrub() would mangle; report() still redacts secrets
    if not rows:
        report("FAIL", "repositories the hub reads", first_line(p.stderr) or "scripts/check-public-repos.sh printed nothing")


def check_registry(auth_file, from_settings=False, label=None):
    section("Registry logins (pre-release builds)")
    names = ["auth file", "quay.io/rhoai login", "registry.stage.redhat.io login", "pull the pinned catalog"]
    if not auth_file:
        report("skipped", "registry logins",
               "no auth file at ~/.config/containers/auth.json or $XDG_RUNTIME_DIR/containers/auth.json; "
               "set QUAY_AUTH_FILE")
        return
    auth_file = os.path.expanduser(auth_file)
    try:
        auths = json.load(open(auth_file)).get("auths", {})
        if not isinstance(auths, dict):
            raise ValueError("auths isn't an object")
    except (OSError, ValueError, AttributeError) as e:
        if os.path.exists(auth_file):
            report("FAIL", "auth file", f"{auth_file}: {type(e).__name__}")
        else:
            report("MISSING", "auth file",
                   f"{auth_file}: not found; " + (HINTS["QUAY_AUTH_FILE"] if from_settings else
                                                   "set QUAY_AUTH_FILE to your auth file, or put it there"))
        for n in names[1:]:
            report("skipped", n, "no readable auth file")
        return
    for entry in auths.values():
        if isinstance(entry, dict) and isinstance(entry.get("auth"), str) and entry["auth"]:
            secrets.append(entry["auth"])
            try:
                user_pass = base64.b64decode(entry["auth"]).decode()
                secrets.extend(p for p in user_pass.split(":", 1) if len(p) >= 4)
            except Exception:
                pass
    report("ok", "auth file", label or auth_file)

    def has(key):
        e = auths.get(key) or auths.get("https://" + key)
        return isinstance(e, dict) and bool(e.get("auth"))

    if has("quay.io/rhoai"):
        report("ok", "quay.io/rhoai login", "quay.io/rhoai entry")
    elif has("quay.io"):
        report("ok", "quay.io/rhoai login",
               "general quay.io entry: set ALLOW_GENERIC_LOGIN: 1 under options: in clusters.yaml (make install) "
               "or run make bootstrap ALLOW_GENERIC_LOGIN=1 (page by page), "
               "or add a robot token for quay.io/rhoai")
    else:
        report("MISSING", "quay.io/rhoai login", "no quay.io/rhoai or quay.io entry with an auth value")
    # The library mirrors registry.redhat.io/rhaii* to stage with NeverContactSource on sites that
    # aren't HCP, so no model runtime pulls there without this login (docs/upstream-main-limits.md, L20).
    if has("registry.stage.redhat.io"):
        report("ok", "registry.stage.redhat.io login", "entry present (model runtime images)")
    else:
        report("FAIL", "registry.stage.redhat.io login",
               "none; required: sites pull model runtimes from registry.stage.redhat.io "
               "(registry.redhat.io/rhaii* is mirrored there with no fallback); "
               "add it to the auth file that has your quay.io/rhoai login, or stage: beside quay: in .config/clusters.yaml (limit L20)")

    image = pinned_catalog_image()
    if not image:
        report("skipped", "pull the pinned catalog", "no image in apps/rhoai/nightly.yaml")
        return
    if not shutil.which("oc"):
        report("skipped", "pull the pinned catalog", "needs oc")
        return
    rc, out, err = run(["oc", "image", "info", "--registry-config", auth_file,
                        "--filter-by-os", "linux/amd64", image], timeout=60)
    short = image.split("@")[0]
    if rc == 0:
        report("ok", "pull the pinned catalog", short)
    else:
        report("FAIL", "pull the pinned catalog", f"{short}: {first_line(err or out) or 'oc image info failed'}")


class LoadError(str):
    """scripts/clusters.sh ran and refused the file: its error, never a secret's value."""


def read_clusters(deployment):
    """[(name, kind)] from DIR/clusters.yaml, kind hub or site, or why not: a LoadError when
    scripts/clusters.sh ran and refused the file, else a string (it couldn't run)."""
    if not clusters_file(deployment):
        return "no clusters.yaml: run cp clusters-example.yaml clusters.yaml and fill it in"
    if not (shutil.which("kubectl") and shutil.which("jq")):
        return "needs kubectl and jq to read clusters.yaml"
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/bin:/bin")
    try:
        p = subprocess.run(["/bin/bash", os.path.join(REPO, "scripts", "clusters.sh"), "--rows", deployment],
                           capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"can't read clusters.yaml: {e}"
    if p.returncode != 0:
        err = next((scrub(line.strip()) for line in p.stderr.splitlines() if line.strip()), "")
        return LoadError(err.removeprefix("error: ") or "can't read clusters.yaml")
    for line in p.stderr.splitlines():  # the ca: ignore warning, which every run prints
        if ": TLS verification off (ca: ignore)" in line:
            print(scrub(line), file=sys.stderr)
    return [tuple(line.split()[:2]) for line in p.stdout.splitlines() if line.strip()]


def check_clusters(deployment):
    rows = read_clusters(deployment)
    if isinstance(rows, str):
        section("Clusters")
        if isinstance(rows, LoadError) and os.path.isfile(os.path.join(deployment, ".config", "clusters.yaml")):
            # make install reads the private file and stops on the same error, such as a REQUIRED- value
            # make config left. scripts/clusters.sh names a secret by its field, never its value.
            report("FAIL", ".config/clusters.yaml", rows)
        else:
            report("skipped", "cluster checks", rows)
        return
    for name, kind in rows:
        check_cluster(name, kind, os.path.join(deployment, ".config", name, "kubeconfig"))


def check_cluster(name, kind, kubeconfig):
    section(f"Hub {name}" if kind == "hub" else f"Site {name}")
    names = ["reachable", "OpenShift 4.21 or later", "cluster-admin", "default StorageClass"]
    if not os.path.isfile(kubeconfig):
        report("skipped", f"{name} checks", f"no login: run make login NAME={name}")
        return
    if not shutil.which("oc"):
        report("skipped", f"{name} checks", "needs oc")
        return

    def oc(*args):
        return run(["oc", "--kubeconfig", kubeconfig, OC_TIMEOUT, *args])

    rc, out, err = oc("whoami", "--show-server")
    if rc != 0:
        report("FAIL", "reachable", f"{name}: {first_line(err) or 'oc whoami failed'}")
        for n in names[1:]:
            report("skipped", n, "cluster not reachable")
        return
    report("ok", "reachable", out.strip())

    rc, out, err = oc("get", "clusterversion", "version", "-o", "jsonpath={.status.desired.version}")
    m = version_of(out) if rc == 0 else None
    if not m:
        report("FAIL", "OpenShift 4.21 or later", first_line(err) or "no version")
    elif (int(m.group(1)), int(m.group(2))) < MIN_OPENSHIFT:
        report("OLD", "OpenShift 4.21 or later", out.strip())
    else:
        report("ok", "OpenShift 4.21 or later", out.strip())

    rc, out, err = oc("auth", "can-i", "*", "*", "--all-namespaces")
    if out.strip() == "yes":
        report("ok", "cluster-admin", "")
    else:
        report("MISSING", "cluster-admin", first_line(out) or first_line(err) or "no")

    rc, out, err = oc("get", "storageclasses.storage.k8s.io", "-o", "json")
    try:
        items = json.loads(out).get("items", []) if rc == 0 else None
    except ValueError:
        items = None
    if items is None:
        report("FAIL", "default StorageClass", first_line(err) or "can't list StorageClasses")
    else:
        default = [i["metadata"]["name"] for i in items
                   if (i["metadata"].get("annotations") or {}).get(
                       "storageclass.kubernetes.io/is-default-class") == "true"]
        if default:
            report("ok", "default StorageClass", ", ".join(default))
        else:
            report("MISSING", "default StorageClass", "no StorageClass is marked default")



def check_catalog_token(path, from_settings=False, label=None):
    section("Catalog token")
    if label:  # from .config/clusters.yaml or the environment: a value, not a file of yours
        report("ok", "catalog token", label)
        return
    if not path:
        report("skipped", "catalog token file",
               "no ~/.ai-grid/catalog-token; set CATALOG_TOKEN_FILE")
        return
    path = os.path.expanduser(path)
    try:
        st = os.stat(path)
    except OSError:
        report("MISSING", "catalog token file",
               f"{path} not found; " + (HINTS["CATALOG_TOKEN_FILE"] if from_settings else
                                        "set CATALOG_TOKEN_FILE to your token file, or put it there"))
        return
    mode = stat.S_IMODE(st.st_mode)
    if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
        report("FAIL", "catalog token file", f"{path} is empty or not a file")
    elif mode & 0o077:
        report("FAIL", "catalog token file", f"{path} is mode {mode:o}; run chmod 600 {path}")
    else:
        report("ok", "catalog token file", f"{path} (mode {mode:o}, not empty)")


def first_existing(*paths):
    """The first of paths that is a file, or None."""
    return next((p for p in paths if p and os.path.isfile(p)), None)


def default_auth_file():
    run_dir = os.environ.get("XDG_RUNTIME_DIR")
    return first_existing(os.path.expanduser("~/.config/containers/auth.json"),
                          run_dir and os.path.join(run_dir, "containers", "auth.json"))


# The files of earlier versions, which make install still reads when nothing else supplies the secret.
INSTALL_DEFAULTS = {"QUAY_AUTH_FILE": ".config/quay-auth.json", "CATALOG_TOKEN_FILE": ".config/catalog-token"}


def clusters_file(deployment):
    """The clusters file the scripts read: .config/clusters.yaml, else clusters.yaml; None without one."""
    for rel in (".config/clusters.yaml", "clusters.yaml"):
        if os.path.isfile(os.path.join(deployment, rel)):
            return os.path.join(deployment, rel)
    return None


def resolved_secrets(deployment):
    """{VAR: (path, source)} for the secret files make install uses, from scripts/clusters.sh
    --resolve (it writes .config/generated/ from .config/clusters.yaml; it prints no secret).
    {} when it can't run."""
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/bin:/bin")
    try:
        p = subprocess.run(["/bin/bash", os.path.join(REPO, "scripts", "clusters.sh"), "--resolve", deployment],
                           capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if p.returncode != 0:
        return {}
    out = {}
    for line in p.stdout.splitlines():
        var, _, rest = line.partition("=")
        path, _, source = rest.partition("\t")
        out[var] = (path, source)
    return out


def from_value(source):
    """A label when the secret came from .config/clusters.yaml or an AI_GRID_ variable, else None."""
    return source if source and (source.startswith("AI_GRID_") or source.endswith("in .config/clusters.yaml")) else None


def deployment_settings(deployment):
    """{KEY: value} for the install settings in DIR/clusters.yaml, read by scripts/clusters.sh
    --settings as scripts/install.sh reads them, or None when it can't be read or sets no
    catalog.url."""
    if not (clusters_file(deployment) and shutil.which("kubectl") and shutil.which("jq")):
        return None
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/bin:/bin")
    try:
        p = subprocess.run(["/bin/bash", os.path.join(REPO, "scripts", "clusters.sh"), "--settings", deployment],
                           capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    settings = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    # Without a catalog, from the file or else the environment as make install takes it,
    # the deployment isn't set up for make install (the page-by-page guide sets none),
    # so the files it uses don't apply.
    catalog = settings["CATALOG_REPO_URL"] if "CATALOG_REPO_URL" in settings else os.environ.get("CATALOG_REPO_URL")
    return settings if catalog else None


def install_path(key, deployment, settings):
    """Where make install looks for KEY when nothing supplies it: its old file under .config/
    (named in the MISSING hint). None page by page."""
    return None if settings is None else os.path.join(deployment, INSTALL_DEFAULTS[key])


def check_old_settings(deployment):
    """make install stops on an install.env, which earlier versions read: say so here first."""
    if os.path.exists(os.path.join(deployment, "install.env")):
        section("Settings")
        report("FAIL", "install.env", "no longer read: move its settings into clusters.yaml "
               "(see clusters-example.yaml), then delete install.env")


def main():
    global LIB
    p = argparse.ArgumentParser(
        description="Report which AI Grid install prerequisites you have. Never blocks; always exits 0.")
    p.add_argument("--deployment", default=REPO, help="your deployment repository (default: this one)")
    p.add_argument("--library", default=LIB, help="your library checkout (default: .library) [LIBRARY]")
    p.add_argument("--quay-auth-file",
                   help="container auth file with your quay.io login [default: what make install uses]")
    p.add_argument("--catalog-token-file",
                   help="file holding the catalog repository token [default: what make install uses]")
    a = p.parse_args()
    LIB = a.library
    settings = deployment_settings(a.deployment)
    resolved = resolved_secrets(a.deployment) if settings is not None else {}
    quay_label = catalog_label = None
    if not a.quay_auth_file and "QUAY_AUTH_FILE" in resolved:
        path, source = resolved["QUAY_AUTH_FILE"]
        a.quay_auth_file, quay_label = path or None, from_value(source)
    if not a.catalog_token_file and "CATALOG_TOKEN_FILE" in resolved:
        path, source = resolved["CATALOG_TOKEN_FILE"]
        a.catalog_token_file, catalog_label = path or None, from_value(source)
    a.quay_auth_file = (a.quay_auth_file or install_path("QUAY_AUTH_FILE", a.deployment, settings)
                        or os.environ.get("QUAY_AUTH_FILE") or default_auth_file())
    a.catalog_token_file = (a.catalog_token_file or install_path("CATALOG_TOKEN_FILE", a.deployment, settings)
                            or os.environ.get("CATALOG_TOKEN_FILE")
                            or first_existing(os.path.expanduser("~/.ai-grid/catalog-token")))

    check_tools()
    check_old_settings(a.deployment)
    check_library(a.deployment)
    check_registry(a.quay_auth_file, settings is not None, quay_label)
    check_clusters(a.deployment)
    check_catalog_token(a.catalog_token_file, settings is not None, catalog_label)
    if settings is not None:
        check_deployment_push(a.deployment, resolved.get("DEPLOYMENT_TOKEN_FILE", ("", "")))
    check_public_repos(a.deployment, settings)

    counts = {s: results.count(s) for s in ("ok", "MISSING", "OLD", "FAIL", "skipped")}
    print("\n" + ", ".join(f"{n} {s.lower()}" for s, n in counts.items() if n))
    if counts["MISSING"] or counts["OLD"] or counts["FAIL"]:
        print("Nothing was changed; fix these before the page that needs them.")
    return 0


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as e:  # never block the install on a bug in this script
        print(f"FAIL     prereqs.py                       internal error: {type(e).__name__}")
    sys.exit(0)
