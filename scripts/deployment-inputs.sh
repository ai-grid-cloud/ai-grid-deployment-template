# Sourced by the deployment scripts in this directory. Renders a deployment
# repository's root/ and reads one input from its generator values:
#   deployment_render DIR   sets $DEPLOYMENT_ROOT to the rendered root
#   deployment_input NAME   prints that input's value
deployment_render() {
  DEPLOYMENT_ROOT="$(oc kustomize "$1/root")" && return 0
  if grep -q 'inputs.env' "$1/root/kustomization.yaml" 2>/dev/null && [ ! -f "$1/root/inputs.env" ]; then
    echo "error: root/inputs.env is missing: run scripts/set-inputs.sh CATALOG_REPO_URL (install guide, page 2)" >&2
  else
    echo "error: oc kustomize $1/root failed" >&2
  fi
  return 1
}
deployment_input() { printf '%s\n' "$DEPLOYMENT_ROOT" | sed -n "s/^ *$1: *//p" | head -1 | tr -d "'\""; }
