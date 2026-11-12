#!/usr/bin/env python3
"""Plan what an AI Grid uninstall deletes, from Argo CD's own inventory.

Reads `oc get applications.argoproj.io -n openshift-gitops -o json` on stdin
and prints one line per object to delete, in order:

    GROUP<TAB>GROUP_VERSION_KIND<TAB>NAMESPACE<TAB>NAME

NAMESPACE is "-" for a cluster-scoped object (shell `read` collapses empty
tab-separated fields).

Every Application records the objects it applied in status.resources. Those,
plus the namespaces Applications create, are what the install put on a
cluster; operators then create the rest, which they remove themselves when
their custom resources are deleted first.

Groups, in the order an uninstall deletes them:

  policies          ACM Policies, Placements and bindings, so nothing is put back
  custom-resources  every other custom resource, while its operator still runs
                    (finalizers: CloudNativePG clusters, ExternalSecrets, ...)
  acm               MultiClusterObservability, then MultiClusterHub (hub only)
  objects           built-in namespaced objects in namespaces that stay
  cluster-scoped    built-in cluster-scoped objects (roles, bindings, webhooks)
  operators         OLM Subscriptions and OperatorGroups (their CSVs at run time)
  namespaces        the namespaces themselves

Never planned: CustomResourceDefinitions (kept, see docs/install/08-uninstall.md),
Argo CD's own Applications, ApplicationSets and ArgoCD (the uninstall stops
Argo CD first and removes it last), anything in a protected namespace, the
protected namespaces themselves, openshift-*, kube-* and default namespaces,
and OLM objects for protected packages.

Usage: uninstall-plan.py --mode hub|site [--site NAME]
                         [--protect-namespaces "A B"] [--protect-packages "A B"]
  --mode hub   Applications whose destination is the hub itself
  --mode site  Applications whose destination is site NAME (by Argo CD cluster
               name, or the cluster proxy URL ending in /NAME)
"""
import argparse
import json
import sys

DEFAULT_PROTECTED_NAMESPACES = (
    "keycloak cert-manager cert-manager-operator openshift-cert-manager-operator openshift-nfd "
    "nvidia-gpu-operator openshift-config openshift-authentication"
).split()
DEFAULT_PROTECTED_PACKAGES = "rhbk-operator openshift-cert-manager-operator nfd gpu-operator-certified".split()

IN_CLUSTER = {"https://kubernetes.default.svc", "in-cluster", "local-cluster"}
BUILTIN_GROUPS = {
    "", "apps", "batch", "rbac.authorization.k8s.io", "networking.k8s.io", "policy", "route.openshift.io",
    "admissionregistration.k8s.io", "scheduling.k8s.io", "storage.k8s.io", "coordination.k8s.io",
    "autoscaling", "discovery.k8s.io", "image.openshift.io", "build.openshift.io", "security.openshift.io",
    "monitoring.coreos.com", "config.openshift.io", "console.openshift.io",
}
ACM_POLICY_KINDS = {
    ("policy.open-cluster-management.io", "Policy"),
    ("policy.open-cluster-management.io", "PlacementBinding"),
    ("policy.open-cluster-management.io", "PolicySet"),
    ("cluster.open-cluster-management.io", "Placement"),
    ("cluster.open-cluster-management.io", "ManagedClusterSetBinding"),
    ("apps.open-cluster-management.io", "PlacementRule"),
}
SKIP_KINDS = {
    ("apiextensions.k8s.io", "CustomResourceDefinition"),
    ("argoproj.io", "Application"),
    ("argoproj.io", "ApplicationSet"),
    ("argoproj.io", "AppProject"),
    ("argoproj.io", "ArgoCD"),
    ("config.openshift.io", "OAuth"),
    ("cert-manager.io", "ClusterIssuer"),
}
OLM_KINDS = {("operators.coreos.com", "Subscription"), ("operators.coreos.com", "OperatorGroup")}
ORDER = ["policies", "custom-resources", "acm", "objects", "cluster-scoped", "operators", "namespaces"]


def system_namespace(ns):
    return ns == "default" or ns.startswith("openshift-") or ns.startswith("kube-")


def targets(app, mode, site):
    dest = app.get("spec", {}).get("destination", {})
    server, name = dest.get("server", ""), dest.get("name", "")
    if mode == "hub":
        return server in IN_CLUSTER or name in IN_CLUSTER
    return name == site or server.rstrip("/").endswith("/" + site)


def plan(apps, mode, site, protected_ns, protected_pkgs):
    planned, skipped = {}, []
    namespaces = set()

    def add(group, gvk, ns, name):
        planned.setdefault((group, gvk, ns, name), True)

    for app in apps:
        if not targets(app, mode, site):
            continue
        spec = app.get("spec", {})
        sync_opts = (spec.get("syncPolicy") or {}).get("syncOptions") or []
        dest_ns = (spec.get("destination") or {}).get("namespace")
        if dest_ns and "CreateNamespace=true" in sync_opts:
            namespaces.add(dest_ns)
        for r in (app.get("status") or {}).get("resources") or []:
            group, kind, ns, name = r.get("group", ""), r.get("kind", ""), r.get("namespace", ""), r.get("name", "")
            version = r.get("version", "")
            gvk = f"{kind}.{version}.{group}" if group else kind
            if (group, kind) in SKIP_KINDS:
                continue
            if ns in protected_ns or (kind == "Namespace" and name in protected_ns):
                skipped.append((gvk, ns, name, "protected namespace"))
                continue
            if kind == "Namespace":
                namespaces.add(name)
                continue
            if (group, kind) in OLM_KINDS:
                if kind == "Subscription" and r.get("name") in protected_pkgs:
                    skipped.append((gvk, ns, name, "protected package"))
                    continue
                add("operators", gvk, ns, name)
            elif (group, kind) in ACM_POLICY_KINDS:
                add("policies", gvk, ns, name)
            elif group == "operator.open-cluster-management.io" and kind == "MultiClusterHub":
                add("acm", gvk, ns, name)
            elif group == "observability.open-cluster-management.io" and kind == "MultiClusterObservability":
                add("acm", gvk, ns, name)
            elif group not in BUILTIN_GROUPS:
                add("custom-resources", gvk, ns, name)
            elif ns:
                add("objects", gvk, ns, name)
            else:
                add("cluster-scoped", gvk, ns, name)

    kept_ns = set()
    for ns in sorted(namespaces):
        if ns in protected_ns:
            skipped.append(("Namespace", "", ns, "protected namespace"))
        elif system_namespace(ns):
            kept_ns.add(ns)
        else:
            add("namespaces", "Namespace", "", ns)
    deleted_ns = {k[3] for k in planned if k[0] == "namespaces"}
    # Built-in objects in a namespace that goes are deleted with it.
    for key in [k for k in planned if k[0] == "objects" and k[2] in deleted_ns]:
        del planned[key]
    # MultiClusterObservability before MultiClusterHub.
    acm_rank = lambda k: 0 if k[1].startswith("MultiClusterObservability") else 1
    rows = sorted(planned, key=lambda k: (ORDER.index(k[0]), acm_rank(k) if k[0] == "acm" else 0, k[1], k[2], k[3]))
    return rows, skipped


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["hub", "site"], required=True)
    p.add_argument("--site", default="")
    p.add_argument("--protect-namespaces", default="")
    p.add_argument("--protect-packages", default="")
    a = p.parse_args()
    if a.mode == "site" and not a.site:
        p.error("--mode site needs --site NAME")
    protected_ns = set(DEFAULT_PROTECTED_NAMESPACES) | set(a.protect_namespaces.split())
    protected_pkgs = set(DEFAULT_PROTECTED_PACKAGES) | set(a.protect_packages.split())
    apps = json.load(sys.stdin).get("items", [])
    rows, skipped = plan(apps, a.mode, a.site, protected_ns, protected_pkgs)
    for group, gvk, ns, name in rows:
        print(f"{group}\t{gvk}\t{ns or '-'}\t{name}")
    for gvk, ns, name, why in skipped:
        print(f"kept ({why}): {gvk} {ns + '/' if ns else ''}{name}", file=sys.stderr)


if __name__ == "__main__":
    main()
