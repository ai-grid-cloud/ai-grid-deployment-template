# Run from your deployment repository. The clusters file names your hub and
# sites; each one's login is .config/NAME/kubeconfig. The scripts fetch the
# library at your pin into .library/ (scripts/library.sh); set LIBRARY to use
# your own checkout.

# Optional; each check prints "skipped" until you set its variable.
export QUAY_AUTH_FILE CATALOG_TOKEN_FILE LIBRARY

.PHONY: help login prereqs test

help: ## Show the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

login: ## Log in to one cluster from the clusters file: make login NAME=hub
	@test -n "$(NAME)" || { echo "usage: make login NAME=<a name from the clusters file>" >&2; exit 2; }
	@scripts/login.sh "$(NAME)"

prereqs: ## Report what is installed and what isn't found; never blocks
	-@scripts/library.sh >/dev/null
	@python3 scripts/prereqs.py

test: ## Run the scripts' tests
	@for t in tests/*-test.sh; do bash "$$t" || exit 1; done
