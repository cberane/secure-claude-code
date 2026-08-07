# Hardened Claude Code sandbox — host-side entry points.
#
# ENGINE selects the container engine: docker (default) or podman.
#   make ENGINE=podman claude
# For podman rootless, additionally export PODMAN_USERNS=keep-id (see README).

-include .env

ENGINE ?= docker
COMPOSE = $(ENGINE) compose

.PHONY: help build up down restart shell claude yolo doctor keygen \
        rotate-signing-key install-hooks clean distclean

help: ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

build: ## Build the sandbox images
	$(COMPOSE) build

up: keygen ## Start the sandbox in the background
	$(COMPOSE) up -d

down: ## Stop the sandbox
	$(COMPOSE) down --remove-orphans

restart: down up ## Restart (required after key rotation)

shell: keygen ## Interactive shell inside the sandbox
	@scripts/check-key-age.sh --context session || true
	$(COMPOSE) run --rm claude-code bash

claude: keygen ## Run Claude Code interactively inside the sandbox
	@scripts/check-key-age.sh --context session || true
	$(COMPOSE) run --rm claude-code claude

yolo: keygen ## Run Claude Code with --dangerously-skip-permissions (the point of this sandbox)
	@scripts/check-key-age.sh --context session || true
	$(COMPOSE) run --rm claude-code claude --dangerously-skip-permissions

keygen: ## Ensure the signing key exists (idempotent, host-side)
	@scripts/ensure-signing-key.sh

rotate-signing-key: ## Rotate the signing key (interactive, host-side)
	@scripts/rotate-signing-key.sh

doctor: keygen ## Run the full hardening self-test (host + container)
	@scripts/doctor.sh --host

install-hooks: ## Install the secret-blocking pre-commit hook into THIS repo
	install -m 0755 security/pre-commit .git/hooks/pre-commit
	@echo "Installed security/pre-commit -> .git/hooks/pre-commit"

clean: ## Remove containers and locally built images (keeps volumes & secrets)
	$(COMPOSE) down --remove-orphans --rmi local

distclean: ## Also remove the claude-config volume (logs you out of Claude)
	$(COMPOSE) down --remove-orphans --rmi local --volumes
