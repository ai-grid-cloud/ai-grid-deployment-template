# Run from your deployment repository. The scripts fetch the library at your
# pin into .library/ (scripts/library.sh); set LIBRARY to use your own checkout.

# Optional; each check prints "skipped" until you set its variable.
export HUB_CONTEXT SITE_CONTEXT QUAY_AUTH_FILE CATALOG_TOKEN_FILE LIBRARY

.PHONY: help prereqs test

help: ## Show the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

prereqs: ## Report what is installed and what isn't found; never blocks
	-@scripts/library.sh >/dev/null
	@python3 scripts/prereqs.py

test: ## Run the scripts' tests
	@for t in tests/*-test.sh; do bash "$$t" || exit 1; done
