# Run from your deployment repository, with the library cloned to ../library
# (install guide, page 2).
LIBRARY ?= ../library

# Optional; each check prints "skipped" until you set its variable.
export HUB_CONTEXT SITE_CONTEXT QUAY_AUTH_FILE CATALOG_TOKEN_FILE

.PHONY: help prereqs

help: ## Show the targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

prereqs: ## Report what is installed and what isn't found; never blocks
	@python3 scripts/prereqs.py --library $(LIBRARY)
