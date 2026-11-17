# Run from your deployment repository. clusters.yaml names your hub and
# sites; each one's login is .config/NAME/kubeconfig. The scripts fetch the
# library at your pin into .library/ (scripts/library.sh); set LIBRARY to use
# your own checkout.

# Optional, for the page-by-page guide and CI: QUAY_AUTH_FILE and
# CATALOG_TOKEN_FILE name files that win over .config/clusters.yaml's secrets
# (scripts/clusters.sh deployment_load); ALLOW_GENERIC_LOGIN=1 lets bootstrap
# use a general quay.io login from such a file; KEYCLOAK_NAMESPACE and
# KEYCLOAK_REALM default to the library Keycloak's maas-db and saas (console-secrets).
export QUAY_AUTH_FILE CATALOG_TOKEN_FILE LIBRARY ALLOW_GENERIC_LOGIN KEYCLOAK_NAMESPACE KEYCLOAK_REALM

.PHONY: help config login prereqs inputs check bootstrap status console-secrets console-call test update \
  site-check site-wipe site-import site-status tenant-call \
  empty-catalog uninstall-site uninstall-hub uninstall-check install provider-admin ready-check

# The site targets work on the only site in clusters.yaml; with several, set
# SITE=NAME. Targets that change a cluster without asking preview by default;
# CONFIRM=1 runs them.
SITE ?=
# A value as one single-quoted shell word, its own quotes escaped.
shq = '$(subst ','\'',$(1))'
need = $(if $($(1)),,$(error set $(1), such as: make $@ $(1)=$(2)))

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

# .config/clusters.yaml holds secrets: .config/ is mode 700 and the file mode 600.
config: ## Create .config/clusters.yaml for you to edit (a copy of clusters.yaml if you have one, else of clusters-example.yaml), secrets included; never overwrites it (page 9)
	@test ! -e .config/clusters.yaml || { echo "error: .config/clusters.yaml already exists; edit it, or move it away first" >&2; exit 1; }
	@src=clusters-example.yaml; test ! -f clusters.yaml || src=clusters.yaml; \
	(umask 077; mkdir -p .config && cp "$$src" .config/clusters.yaml) && chmod 700 .config && chmod 600 .config/clusters.yaml && \
	if [ "$$src" = clusters.yaml ]; then echo "Copied clusters.yaml to .config/clusters.yaml (readable only by you): the scripts read it from now on, so edit that one."; \
	else echo "Created .config/clusters.yaml from clusters-example.yaml (readable only by you): edit it."; fi

login: ## Log in to each cluster that needs it, with its stored credentials, else the browser; NAME=... for one
	@scripts/login.sh $(if $(filter 1,$(NONINTERACTIVE)),--non-interactive) $(NAME)

prereqs: ## Report what is installed and what isn't found; never blocks
	-@scripts/library.sh >/dev/null
	@python3 scripts/prereqs.py

inputs: ## Set root/inputs.env, then check; CATALOG=URL (page 2); make install reads catalog.url
	@scripts/set-inputs.sh $(if $(CATALOG),$(call shq,$(CATALOG)))

check: ## Check this repository before you push it: renders, every input set; read-only (page 2)
	@scripts/check-deployment.sh

bootstrap: ## Install OpenShift GitOps on the hub and apply root/ (page 3)
	@scripts/bootstrap-hub.sh

status: ## Show how the hub's install is going; read-only (pages 3 and 4)
	@scripts/status.sh

console-secrets: ## Create the console's secrets from your catalog token (page 4)
	@scripts/create-console-secrets.sh

# The recipe reads METHOD, BODY and BODY_FILE from its environment (make exports
# them from the command line), so quotes and newlines arrive as typed. Make still
# expands a $ in a command-line BODY: use BODY_FILE for that.
console-call: ## Call the console's API as your hub login: METHOD=..., BODY='JSON', or BODY_FILE=... for several lines or a $ (page 7)
	@$(call need,METHOD,ai_grid.v1.Tenants/List)
	@$(if $(and $(BODY),$(BODY_FILE)),$(error set BODY or BODY_FILE, not both))
	@$(if $(BODY_FILE),test -r "$$BODY_FILE" && test -s "$$BODY_FILE" || { echo "error: can't read BODY_FILE $$BODY_FILE (missing or empty)" >&2; exit 2; })
	@scripts/console-call.sh "$$METHOD" $(if $(BODY_FILE),"$$(cat "$$BODY_FILE")","$$BODY")

test: ## Run the template's own tests (for maintainers)
	@for t in tests/*-test.sh; do bash "$$t" || exit 1; done

update: ## Merge the template's latest main into this repository; never pushes
	@scripts/update-from-template.sh

site-check: ## Check a site before you import it; read-only (page 5)
	@scripts/site-check.sh $(SITE)

site-wipe: ## Preview removing a site's old install; CONFIRM=1 removes it (page 5)
	@scripts/wipe-site.sh $(if $(SITE),--site $(SITE)) $(if $(CONFIRM),,--dry-run)

site-import: ## Preview importing a site into the hub's ACM; CONFIRM=1 imports it (page 5)
	@scripts/import-site.sh $(SITE) $(if $(CONFIRM),--yes)

site-status: ## Show a site's ACM state, hub Applications, MaaS host and models; read-only
	@scripts/site-status.sh $(SITE)

tenant-call: ## Call a model with a tenant's API key: KEY_FILE=... MODEL=... [SUBSCRIPTION=...] (page 7)
	@$(call need,KEY_FILE,KEY_FILE)$(call need,MODEL,MODEL_NAME)
	@scripts/tenant-call.sh --key-file "$(KEY_FILE)" --model "$(MODEL)" $(if $(SUBSCRIPTION),--subscription "$(SUBSCRIPTION)") $(if $(SITE),--site $(SITE))

empty-catalog: ## Preview emptying your catalog repository; CONFIRM=1 commits and pushes (page 8)
	@scripts/empty-catalog.sh $(if $(CONFIRM),--confirm)

uninstall-site: ## Preview a site's uninstall; CONFIRM=1 runs it (page 8)
	@n=$$(scripts/clusters.sh --site $(SITE)) && mkdir -p .uninstall && \
	  scripts/uninstall.sh site "$$n" $(if $(CONFIRM),--plan-file ".uninstall/$$n-plan.tsv",--dry-run)

uninstall-hub: ## Preview the hub's uninstall; CONFIRM=1 runs it (page 8)
	@mkdir -p .uninstall && scripts/uninstall.sh hub $(if $(CONFIRM),--plan-file .uninstall/hub-plan.tsv,--dry-run)

uninstall-check: ## After an uninstall, show what is left on each cluster; read-only (page 8)
	@scripts/uninstall-check.sh

install: ## Install the hub and import every site, unattended (page 9); HUB_ONLY=1 for the hub alone
	@scripts/install.sh $(if $(filter 1,$(HUB_ONLY)),--hub-only)

provider-admin: ## Create the provider-admin ServiceAccount and its token
	@scripts/provider-admin.sh

ready-check: ## Check the installed end state and write .install/outputs.json; IN_USE=1 on a hub in use; read-only
	@scripts/ready-check.sh $(if $(IN_USE),--in-use)
