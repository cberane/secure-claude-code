# Hardened Claude Code sandbox — host-side entry points.
#
# ENGINE selects the container engine: docker (default) or podman.
#   make ENGINE=podman claude
# For podman rootless, additionally export PODMAN_USERNS=keep-id (see docs/podman.md).

# NOTE: Make's include cannot parse everything compose can — values
# containing '#' (truncated) or '$' (expanded) get mangled here. preflight
# warns about them; simplest is to avoid both characters in .env values.
-include .env

ENGINE ?= docker
export ENGINE

# Rotation policy must reach host-side script runs too (check-key-age.sh in
# shell/claude/yolo) — without the export, .env values would apply inside
# the container but silently not on the host.
export SIGNING_KEY_WARN_DAYS SIGNING_KEY_MAX_DAYS SIGNING_KEY_ENFORCE

# The dind sidecar lives behind a compose profile so it only exists when
# the docker toolchain is enabled in .env (TOOLCHAINS=...,docker).
ifneq (,$(findstring docker,$(TOOLCHAINS)))
export COMPOSE_PROFILES=docker
endif

# Every profile that can hold running containers. Teardown must not depend
# on the CURRENT .env: a profile-disabled service is not an orphan, so
# `down --remove-orphans` would leave the dind sidecars running forever
# once "docker" is dropped from TOOLCHAINS.
ALL_PROFILES = docker

# Compose file list, always explicit (identical to docker's auto-loading,
# and required anyway for podman and for the learning overlay).
COMPOSE_FILES = -f docker-compose.yml
ifeq ($(ENGINE),podman)
COMPOSE_FILES += -f compose.podman.yml
endif
ifneq ($(wildcard docker-compose.override.yml),)
COMPOSE_FILES += -f docker-compose.override.yml
endif
# Egress learning mode (make learn / make learn-off): while the marker
# exists, the proxy runs open+logging and sessions start WITHOUT the
# signing key (compose.learning.yml). Last file wins on conflicts.
ifneq (,$(wildcard .learning-mode))
export EGRESS_MODE = learning
COMPOSE_FILES += -f compose.learning.yml
endif
COMPOSE = $(ENGINE) compose $(COMPOSE_FILES)

# Teardown variant: sees every profile, so nothing is left behind.
COMPOSE_ALL = COMPOSE_PROFILES=$(ALL_PROFILES) $(COMPOSE)

# Docker client talking to the NESTED daemon, from the host. Its images,
# containers and build cache live inside the dind-storage volume and are
# invisible to the host engine's own `system df`. Resolves the container id
# via compose, so it works with any project/container naming.
DIND_EXEC = cid=$$($(COMPOSE_ALL) ps -q dind-daemon 2>/dev/null); \
            [ -n "$$cid" ] || { echo "dind sidecar is not running (TOOLCHAINS must contain 'docker'; then: make up)"; exit 1; }; \
            $(ENGINE) exec "$$cid" docker -H tcp://127.0.0.1:2375

# Start an interactive session container. It carries the stable name
# claude-session so the host ingress can forward to it (ingress/haproxy.cfg).
# A name belongs to exactly one container, so a SECOND parallel session must
# start unnamed rather than fail — `make shell` next to a running `make yolo`
# is a normal thing to want. A stale, non-running leftover of that name is
# reclaimed instead.
define session
	@if [ -n "$$($(ENGINE) ps -aq -f name='^claude-session$$')" ] \
	    && [ -z "$$($(ENGINE) ps -q  -f name='^claude-session$$')" ]; then \
	        $(ENGINE) rm -f claude-session >/dev/null; \
	fi
	@scripts/check-key-age.sh --context session || true
	@if [ -n "$$($(ENGINE) ps -q -f name='^claude-session$$')" ]; then \
	    echo "note: another session already holds the name 'claude-session'."; \
	    echo "      starting this one unnamed — host ingress keeps targeting the first."; \
	    $(COMPOSE) run --rm claude-code $(1); \
	else \
	    $(COMPOSE) run --rm --name claude-session claude-code $(1); \
	fi
endef

# Printed before anything that kills a running agent session.
WARN_SESSION = @if [ -n "$$($(ENGINE) ps -q -f name='^claude-session$$')" ]; then \
                   echo "WARNING: an interactive session (claude-session) is running and will be killed."; \
               fi

.PHONY: help preflight build up down stop restart shell claude yolo doctor \
        learn learn-off _learn-apply learned \
        keygen rotate-signing-key install-hooks prune prune-build prune-dind \
        clean clean-dind \
        distclean reload-egress reload-images reload-ingress ps logs denied df

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

preflight: ## Check host prerequisites (runs automatically before build/start)
	@scripts/preflight.sh

# Local egress allowlist: created from the template once, then never touched
# by make again — local edits survive template updates from git.
egress/allowlist.txt:
	cp egress/allowlist.template.txt $@
	@echo "Created local $@ from template (gitignored — edit freely)."

# Local dind image-pull allowlist: same template pattern.
dind/images-allowlist.txt:
	cp dind/images-allowlist.template.txt $@
	@echo "Created local $@ from template (gitignored — edit freely)."

build: preflight egress/allowlist.txt dind/images-allowlist.txt ## Build the sandbox images
	$(COMPOSE) build

up: preflight keygen egress/allowlist.txt dind/images-allowlist.txt ## Start the sandbox in the background
	$(COMPOSE) up -d

down: ## Stop the sandbox (incl. dind sidecars and the interactive session)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans

stop: ## Stop containers but keep them (gentler than down; no removal)
	$(WARN_SESSION)
	$(COMPOSE_ALL) stop

restart: down up ## Full restart — also drops the dind sidecar and with it every nested container

shell: preflight keygen egress/allowlist.txt dind/images-allowlist.txt ## Interactive shell inside the sandbox
	$(call session,bash)

claude: preflight keygen egress/allowlist.txt dind/images-allowlist.txt ## Run Claude Code interactively inside the sandbox
	$(call session,claude)

yolo: preflight keygen egress/allowlist.txt dind/images-allowlist.txt ## Run Claude Code with --dangerously-skip-permissions (the point of this sandbox)
	$(call session,claude --dangerously-skip-permissions)

# --- surgical reloads ------------------------------------------------------
# Apply a policy change WITHOUT tearing the sandbox down. `make restart`
# stops the dind sidecar too, which kills every nested container (Sail
# databases, mailpit, ...) — far too blunt for a one-line allowlist edit.

reload-egress: egress/allowlist.txt ## Apply an egress allowlist edit (rebuilds only the proxy)
	$(COMPOSE) build egress-proxy
	$(COMPOSE) up -d --no-deps egress-proxy
	@echo "egress-proxy reloaded — running sessions kept; its denial log starts empty again."

reload-images: dind/images-allowlist.txt ## Apply a dind image-allowlist edit (recreates only the guard)
	$(COMPOSE_ALL) up -d --no-deps --force-recreate dind-guard
	@echo "dind-guard reloaded — the daemon and its containers kept running."

reload-ingress: ## Apply an ingress port/config change (recreates only the ingress)
	@$(COMPOSE) config --services | grep -qx ingress \
	    || { echo "no 'ingress' service — enable it in docker-compose.override.yml (see docker-compose.override.example.yml)"; exit 1; }
	$(COMPOSE) up -d --no-deps ingress

# --- egress learning mode --------------------------------------------------
# One open research pass that logs every contacted domain, then distills
# the minimal allowlist. NOT the hardened posture: doctor stays red while
# active, and sessions run WITHOUT the signing key (see docs/workflow.md).

learn: preflight ## Enter egress learning mode (open egress, logged; signing key removed)
	@touch .learning-mode
	@$(MAKE) --no-print-directory EGRESS_MODE=learning _learn-apply
	@echo
	@echo "LEARNING MODE ACTIVE — egress is OPEN (LAN + git hosts still denied)."
	@echo "  * Start a FRESH session (make claude/yolo) — it runs without the"
	@echo "    signing key; sessions started earlier still carry it: close them."
	@echo "  * Do not mount secret-bearing projects while this mode is on."
	@echo "  * Distill with 'make learned'; leave with 'make learn-off'."

learn-off: ## Leave learning mode and rebake the proxy with the (updated) allowlist
	@rm -f .learning-mode
	@$(MAKE) --no-print-directory EGRESS_MODE=allowlist _learn-apply
	@echo
	@echo "Learning mode OFF — allowlist enforced again. Rerun the task to"
	@echo "verify the curated list is complete (blocked-domains catches gaps),"
	@echo "and run 'make doctor' to confirm the posture is green."

# Re-entered via $(MAKE) so the marker created/removed above is seen by a
# fresh Makefile evaluation (COMPOSE/EGRESS_MODE are computed at parse time).
_learn-apply:
	$(COMPOSE) build egress-proxy
	$(COMPOSE) up -d --no-deps egress-proxy

learned: ## Distill the domains used in learning mode into an allowlist block
	@$(COMPOSE) run --rm --no-deps -T claude-code learned-domains

keygen: ## Ensure the signing key exists (idempotent, host-side)
	@scripts/ensure-signing-key.sh

rotate-signing-key: ## Rotate the signing key (interactive, host-side)
	@scripts/rotate-signing-key.sh

doctor: preflight keygen egress/allowlist.txt dind/images-allowlist.txt ## Run the full hardening self-test (host + container)
	@scripts/doctor.sh --host

install-hooks: ## Install the secret-blocking pre-commit hook into THIS repo
	install -m 0755 security/pre-commit .git/hooks/pre-commit
	@echo "Installed security/pre-commit -> .git/hooks/pre-commit"

ps: ## Show sandbox containers — outer AND the ones nested inside dind
	@$(COMPOSE_ALL) ps
	@cid=$$($(COMPOSE_ALL) ps -q dind-daemon 2>/dev/null); \
	 if [ -n "$$cid" ]; then \
	     echo; echo "=== nested inside dind (invisible to the host's docker ps) ==="; \
	     $(ENGINE) exec "$$cid" docker -H tcp://127.0.0.1:2375 ps -a; \
	 fi

logs: ## Follow the sandbox logs (proxy denials, dind, ingress)
	$(COMPOSE_ALL) logs -f --tail=100

denied: ## List domains the egress proxy denied since its last restart
	@$(COMPOSE) run --rm -T claude-code blocked-domains

df: ## Show disk usage of the host engine AND of the nested dind daemon
	@echo "=== host engine ==="
	@$(ENGINE) system df
	@cid=$$($(COMPOSE_ALL) ps -q dind-daemon 2>/dev/null); \
	 if [ -n "$$cid" ]; then \
	     echo; echo "=== dind sidecar (all of it inside the dind-storage volume) ==="; \
	     $(ENGINE) exec "$$cid" docker -H tcp://127.0.0.1:2375 system df; \
	 fi

prune: ## Reclaim disk space from dangling images (safe: untagged layers only)
	$(ENGINE) image prune -f

prune-build: ## Reclaim the host build cache (safe; only makes the next build slower)
	$(ENGINE) builder prune -f

prune-dind: ## Reclaim disk INSIDE dind (stopped containers, dangling images, build cache)
	@$(DIND_EXEC) system prune -f

clean: ## Remove containers and locally built images (keeps volumes & secrets)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans --rmi local

clean-dind: ## Drop the dind image/layer storage (keeps your Claude login)
	$(WARN_SESSION)
	$(COMPOSE_ALL) rm -sf dind-daemon dind-guard
	$(ENGINE) volume rm claude-sandbox_dind-storage

distclean: ## Also remove ALL volumes (logs you out of Claude, drops dind storage)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans --rmi local --volumes
