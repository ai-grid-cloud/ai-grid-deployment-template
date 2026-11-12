# Run from your deployment repository. clusters.yaml names your hub and
# sites; each one's login is .config/NAME/kubeconfig. The scripts fetch the
# library at your pin into .library/ (scripts/library.sh); set LIBRARY to use
# your own checkout.

# Optional. QUAY_AUTH_FILE defaults to ~/.config/containers/auth.json, else
# $XDG_RUNTIME_DIR/containers/auth.json; ALLOW_GENERIC_LOGIN=1 lets bootstrap
# use a general quay.io login.
export QUAY_AUTH_FILE CATALOG_TOKEN_FILE LIBRARY ALLOW_GENERIC_LOGIN

.PHONY: help login prereqs bootstrap test update

help: ## Show the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

login: ## Log in to each cluster in clusters.yaml that needs it; NAME=... for one
	@scripts/login.sh $(NAME)

prereqs: ## Report what is installed and what isn't found; never blocks
	-@scripts/library.sh >/dev/null
	@python3 scripts/prereqs.py

bootstrap: ## Install OpenShift GitOps on the hub and apply root/ (page 3)
	@scripts/bootstrap-hub.sh

test: ## Run the scripts' tests
	@for t in tests/*-test.sh; do bash "$$t" || exit 1; done

update: ## Merge the template's latest main into this repository; never pushes
	@scripts/update-from-template.sh
