#!/usr/bin/env python3
"""Report which AI Grid install prerequisites you have. Never blocks, never changes anything.

Usage: scripts/prereqs.py [--library DIR] [--deployment DIR]
                          [--quay-auth-file FILE] [--catalog-token-file FILE]

Runs from your deployment repository; the library is .library/, which make prereqs fetches
at your pin (scripts/library.sh).

The clusters come from the deployment's clusters.yaml, each with its login in
.config/NAME/kubeconfig. Each option also reads an environment variable:
QUAY_AUTH_FILE, CATALOG_TOKEN_FILE and LIBRARY. Unset, QUAY_AUTH_FILE is the first of
~/.config/containers/auth.json and $XDG_RUNTIME_DIR/containers/auth.json that exists,
and CATALOG_TOKEN_FILE is ~/.ai-grid/catalog-token if it exists. A check whose input
you haven't set prints "skipped". Every line is: status, name, detail. Statuses: ok, MISSING,
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
        report("skipped", "library at your pin", "pass --deployment DIR (make prereqs does)")
        return
    k = os.path.join(deployment, "root", "kustomization.yaml")
    try:
        text = open(k).read()
    except OSError:
        report("FAIL", "library at your pin", f"can't read {k}")
        return
    m = re.search(r"^\s*libraryRevision:\s*(\S+)", text, re.M)
    if not m:
        report("FAIL", "library at your pin", f"no libraryRevision in {k}")
        return
    pin = m.group(1)
    lib = os.path.relpath(LIB)
    if not os.path.exists(os.path.join(LIB, ".git")):
        report("FAIL", "library at your pin", f"no library checkout at {lib}: run scripts/library.sh")
        return
    rc, out, _ = run(["git", "-C", LIB, "rev-parse", "HEAD"], timeout=5)
    head = out.strip()
    if rc == 0 and head == pin:
        report("ok", "library at your pin", pin[:12])
    else:
        report("FAIL", "library at your pin",
               f"{lib} is at {head[:12] or 'unknown'}, not {pin[:12]}: git -C {lib} checkout -q {pin}")


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


def check_registry(auth_file):
    section("Registry logins (pre-release builds)")
    names = ["auth file", "quay.io/rhoai login", "registry.stage.redhat.io login", "pull the pinned catalog"]
    if not auth_file:
        report("skipped", "registry logins",
               "no auth file at ~/.config/containers/auth.json or $XDG_RUNTIME_DIR/containers/auth.json; "
               "set QUAY_AUTH_FILE to yours")
        return
    auth_file = os.path.expanduser(auth_file)
    try:
        auths = json.load(open(auth_file)).get("auths", {})
        if not isinstance(auths, dict):
            raise ValueError("auths isn't an object")
    except (OSError, ValueError, AttributeError) as e:
        report("FAIL" if os.path.exists(auth_file) else "MISSING", "auth file",
               f"{auth_file}: {type(e).__name__}")
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
    report("ok", "auth file", auth_file)

    def has(key):
        e = auths.get(key) or auths.get("https://" + key)
        return isinstance(e, dict) and bool(e.get("auth"))

    if has("quay.io/rhoai"):
        report("ok", "quay.io/rhoai login", "quay.io/rhoai entry")
    elif has("quay.io"):
        report("ok", "quay.io/rhoai login",
               "general quay.io entry: page 3 needs RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1, "
               "or add a robot token for quay.io/rhoai")
    else:
        report("MISSING", "quay.io/rhoai login", "no quay.io/rhoai or quay.io entry with an auth value")
    if has("registry.stage.redhat.io"):
        report("ok", "registry.stage.redhat.io login", "entry present (model runtime images)")
    else:
        report("MISSING", "registry.stage.redhat.io login",
               "page 7's model runtime images (registry.redhat.io/rhaii*, mirrored to registry.stage.redhat.io) "
               "won't pull; add this login to the auth file before page 3 (page 2)")

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


ROLES = ("hub", "combined", "ingress", "inference")


def read_clusters(deployment):
    """[(name, role)] from DIR/clusters.yaml, or an error string. scripts/clusters.sh reads and checks it."""
    if not os.path.isfile(os.path.join(deployment, "clusters.yaml")):
        return "no clusters.yaml: copy clusters-example.yaml to clusters.yaml and edit it (page 2, part 1)"
    if not (shutil.which("kubectl") and shutil.which("jq")):
        return "needs kubectl and jq to read clusters.yaml"
    env = dict(os.environ, PATH=os.environ.get("PATH", "") + ":/usr/bin:/bin")
    try:
        p = subprocess.run(["/bin/bash", os.path.join(REPO, "scripts", "clusters.sh"), "--rows", deployment],
                           capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"can't read clusters.yaml: {e}"
    if p.returncode != 0:
        return first_line(p.stderr).removeprefix("error: ") or "can't read clusters.yaml"
    return [tuple(line.split()[:2]) for line in p.stdout.splitlines() if line.strip()]


def check_clusters(deployment):
    rows = read_clusters(deployment)
    if isinstance(rows, str):
        section("Clusters")
        report("skipped", "cluster checks", rows)
        return
    for name, role in rows:
        check_cluster(name, role, os.path.join(deployment, ".config", name, "kubeconfig"))


def check_cluster(name, role, kubeconfig):
    site = role != "hub"
    section(f"Site {name} ({role})" if site else f"Hub {name}")
    names = ["reachable", "OpenShift 4.21 or later", "cluster-admin", "default StorageClass"]
    if role in ("combined", "ingress"):
        names.append("ClusterIssuer")
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

    if "ClusterIssuer" not in names:
        return
    rc, out, err = oc("get", "clusterissuers.cert-manager.io", "-o", "json")
    try:
        items = json.loads(out).get("items", []) if rc == 0 else None
    except ValueError:
        items = None
    if items is None:
        report("MISSING", "ClusterIssuer", first_line(err) or "can't list ClusterIssuers (is cert-manager installed?)")
    elif not items:
        report("MISSING", "ClusterIssuer", "none; the site needs one that issues by DNS-01")
    else:
        parts = []
        for i in items:
            solvers = (((i.get("spec") or {}).get("acme") or {}).get("solvers")) or []
            dns01 = any(isinstance(s, dict) and s.get("dns01") for s in solvers)
            parts.append(f"{i['metadata']['name']} ({'DNS-01' if dns01 else 'no DNS-01'})")
        status = "ok" if any("(DNS-01)" in p for p in parts) else "MISSING"
        report(status, "ClusterIssuer", ", ".join(parts))


def check_catalog_token(path):
    section("Catalog token")
    if not path:
        report("skipped", "catalog token file",
               "no ~/.ai-grid/catalog-token yet (page 2, part 2); or set CATALOG_TOKEN_FILE")
        return
    path = os.path.expanduser(path)
    try:
        st = os.stat(path)
    except OSError:
        report("MISSING", "catalog token file", f"{path} not found")
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


def main():
    global LIB
    p = argparse.ArgumentParser(
        description="Report which AI Grid install prerequisites you have. Never blocks; always exits 0.")
    p.add_argument("--deployment", default=REPO, help="your deployment repository (default: this one)")
    p.add_argument("--library", default=LIB, help="your library checkout (default: .library) [LIBRARY]")
    p.add_argument("--quay-auth-file", default=os.environ.get("QUAY_AUTH_FILE") or default_auth_file(),
                   help="container auth file with the pre-release registry logins [QUAY_AUTH_FILE]")
    p.add_argument("--catalog-token-file",
                   default=(os.environ.get("CATALOG_TOKEN_FILE")
                            or first_existing(os.path.expanduser("~/.ai-grid/catalog-token"))),
                   help="file holding the catalog repository token [CATALOG_TOKEN_FILE]")
    a = p.parse_args()
    LIB = a.library

    check_tools()
    check_library(a.deployment)
    check_registry(a.quay_auth_file)
    check_clusters(a.deployment)
    check_catalog_token(a.catalog_token_file)

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
