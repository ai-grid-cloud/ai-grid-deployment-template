# Run from your deployment repository. clusters.yaml names your hub and
# sites; each one's login is .config/NAME/kubeconfig. The scripts fetch the
# library at your pin into .library/ (scripts/library.sh); set LIBRARY to use
# your own checkout.

# Optional. QUAY_AUTH_FILE defaults to ~/.config/containers/auth.json, else
# $XDG_RUNTIME_DIR/containers/auth.json; ALLOW_GENERIC_LOGIN=1 lets bootstrap
# use a general quay.io login. CATALOG_TOKEN_FILE defaults to
# ~/.ai-grid/catalog-token; KEYCLOAK_NAMESPACE and KEYCLOAK_REALM to the
# template's tenant-idp and tenants (console-secrets).
export QUAY_AUTH_FILE CATALOG_TOKEN_FILE LIBRARY ALLOW_GENERIC_LOGIN KEYCLOAK_NAMESPACE KEYCLOAK_REALM

.PHONY: help login prereqs bootstrap status console-secrets test update \
  site-check site-wipe site-import site-add site-join site-status tenant-user tenant-call \
  empty-catalog uninstall-site uninstall-hub uninstall-check

# The site targets work on the only site in clusters.yaml; with several, set
# SITE=NAME. Targets that change a cluster without asking preview by default;
# CONFIRM=1 runs them.
SITE ?=
need = $(if $($(1)),,$(error set $(1), such as: make $@ $(1)=$(2)))

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /: /'

login: ## Log in to each cluster in clusters.yaml that needs it; NAME=... for one
	@scripts/login.sh $(NAME)

prereqs: ## Report what is installed and what isn't found; never blocks
	-@scripts/library.sh >/dev/null
	@python3 scripts/prereqs.py

bootstrap: ## Install OpenShift GitOps on the hub and apply root/ (page 3)
	@scripts/bootstrap-hub.sh

status: ## Show how the hub's install is going; read-only (page 4)
	@scripts/status.sh

console-secrets: ## Create the console's secrets from your catalog token (page 4)
	@scripts/create-console-secrets.sh

test: ## Run the scripts' tests
	@for t in tests/*-test.sh; do bash "$$t" || exit 1; done

update: ## Merge the template's latest main into this repository; never pushes
	@scripts/update-from-template.sh

site-check: ## Check a site before you import it; read-only (page 5)
	@scripts/site-check.sh $(SITE)

site-wipe: ## Preview removing a site's old install; CONFIRM=1 removes it (page 5)
	@scripts/wipe-site.sh $(if $(SITE),--site $(SITE)) $(if $(CONFIRM),,--dry-run)

site-import: ## Import a site into the hub's ACM, after a y/N prompt (page 5)
	@scripts/import-site.sh $(SITE)

site-add: ## Write an ingress or combined site's files; ISSUER=... if it has several (page 6)
	@n=$$(scripts/clusters.sh --site $(SITE)) && scripts/add-site.sh "$$n" $(ISSUER)

site-join: ## Label a site on the hub so the hub installs it (page 6)
	@scripts/join-site.sh $(SITE)

site-status: ## Show a site's ACM state, hub Applications, MaaS host and models; read-only
	@scripts/site-status.sh $(SITE)

tenant-user: ## Create a test tenant user: ORG=... TENANT_USER=... PASSWORD_FILE=... (page 7)
	@$(call need,ORG,ORG_NAME)$(call need,TENANT_USER,TENANT_USER)$(call need,PASSWORD_FILE,PASSWORD_FILE)
	@scripts/create-test-tenant.sh --kubeconfig ".config/$$(scripts/clusters.sh --hub)/kubeconfig" --org "$(ORG)" \
	  --user "$(TENANT_USER)" --password-file "$(PASSWORD_FILE)"

tenant-call: ## Call a model as that user: TENANT_USER, PASSWORD_FILE, SUBSCRIPTION, MODEL (page 7)
	@$(call need,TENANT_USER,TENANT_USER)$(call need,PASSWORD_FILE,PASSWORD_FILE)
	@$(call need,SUBSCRIPTION,SUBSCRIPTION_ID)$(call need,MODEL,MODEL_NAME)
	@scripts/tenant-call.sh --user "$(TENANT_USER)" --password-file "$(PASSWORD_FILE)" --subscription "$(SUBSCRIPTION)" \
	  --model "$(MODEL)" $(if $(SITE),--site $(SITE))

empty-catalog: ## Preview emptying your catalog repository; CONFIRM=1 commits and pushes (page 8)
	@scripts/empty-catalog.sh $(if $(CONFIRM),--confirm)

uninstall-site: ## Preview a site's uninstall; CONFIRM=1 runs it (page 8)
	@n=$$(scripts/clusters.sh --site $(SITE)) && mkdir -p .uninstall && \
	  scripts/uninstall.sh site "$$n" $(if $(CONFIRM),--plan-file ".uninstall/$$n-plan.tsv",--dry-run)

uninstall-hub: ## Preview the hub's uninstall; CONFIRM=1 runs it (page 8)
	@mkdir -p .uninstall && scripts/uninstall.sh hub $(if $(CONFIRM),--plan-file .uninstall/hub-plan.tsv,--dry-run)

uninstall-check: ## After an uninstall, show what is left on each cluster; read-only (page 8)
	@scripts/uninstall-check.sh
