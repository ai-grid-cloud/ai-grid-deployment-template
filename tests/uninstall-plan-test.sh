#!/usr/bin/env bash
# Tests for scripts/uninstall-plan.py against tests/fixtures/uninstall-applications.json.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
F=tests/fixtures/uninstall-applications.json
total=0 fails=0
hub=$(python3 scripts/uninstall-plan.py --mode hub < "$F" 2>/dev/null)
hub_err=$(python3 scripts/uninstall-plan.py --mode hub < "$F" 2>&1 >/dev/null)
site=$(python3 scripts/uninstall-plan.py --mode site --site site-b < "$F" 2>/dev/null)
site_err=$(python3 scripts/uninstall-plan.py --mode site --site site-b < "$F" 2>&1 >/dev/null)
extra=$(python3 scripts/uninstall-plan.py --mode hub --protect-namespaces maas-db < "$F" 2>/dev/null)

ok() { total=$((total+1)); if eval "$2"; then echo "   ok   $1"; else fails=$((fails+1)); echo "   FAIL $1"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
line() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

ok "policies come first" '[ "$(head -1 <<<"$hub" | cut -f1)" = policies ]'
ok "a custom resource is deleted before its operator" '[ "$(line "$hub" "Cluster.v1.postgresql.cnpg.io")" -lt "$(line "$hub" "Subscription.v1alpha1.operators.coreos.com")" ]'
ok "MultiClusterObservability before MultiClusterHub" '[ "$(line "$hub" MultiClusterObservability)" -lt "$(line "$hub" MultiClusterHub)" ]'
ok "MultiClusterHub before operators" '[ "$(line "$hub" MultiClusterHub)" -lt "$(line "$hub" "operators	")" ]'
ok "namespaces last" '[ "$(tail -1 <<<"$hub" | cut -f1)" = namespaces ]'
ok "built-in objects in a deleted namespace aren't listed" '! has "$hub" "maas-db-app"'
ok "namespaces the install created are deleted" 'has "$hub" "namespaces	Namespace	-	maas-db" && has "$hub" "namespaces	Namespace	-	cnpg-system"'
ok "CRDs are kept" '! has "$hub" CustomResourceDefinition'
ok "Argo CD objects are left to the Argo CD step" '! has "$hub" ApplicationSet'
ok "the ArgoCD instance is left to the GitOps step" '! has "$hub" "ArgoCD.v1beta1.argoproj.io"'
ok "cluster-scoped objects are planned" 'has "$hub" "cluster-scoped	ClusterRoleBinding.v1.rbac.authorization.k8s.io	-	cluster-admin-admin"'
ok "objects in a protected namespace are kept and reported" '! has "$hub" "openshift-config	something" && has "$hub_err" "kept (protected namespace): ConfigMap openshift-config/something"'
ok "objects in a system namespace are deleted, the namespace isn't" 'has "$hub" "objects	ConfigMap	openshift-ingress	kept-ns-object" && ! has "$hub" "Namespace	-	openshift-gitops"'
ok "hub mode leaves site Applications out" '! has "$hub" DataScienceCluster'
ok "site mode takes the site's Applications only" 'has "$site" DataScienceCluster && ! has "$site" MultiClusterHub'
ok "site mode keeps a protected package's namespace" '! has "$site" "openshift-nfd" && has "$site_err" "kept (protected namespace): Subscription.v1alpha1.operators.coreos.com openshift-nfd/nfd"'
ok "a deployment can protect more namespaces" '! has "$extra" "Namespace	-	maas-db" && ! has "$extra" "Cluster.v1.postgresql.cnpg.io"'
ok "site mode needs --site" '! python3 scripts/uninstall-plan.py --mode site < "$F" >/dev/null 2>&1'
echo "uninstall-plan tests: $((total-fails)) ok, $fails failed"; exit "$fails"
