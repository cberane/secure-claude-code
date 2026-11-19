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

# Dev-CA leaf validity (docs/https.md) — reaches the host-side mint/renew
# scripts the same way.
export CERT_DAYS

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
	@scripts/renew-certs.sh --auto || true
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

.PHONY: help preflight build up down stop restart shell claude yolo doctor status update-sandbox-skills \
        workspaces workspace new-workspace add-workspace gh-token gh-renew gh-app gh-app-wire install-scc ws-prune ws-rm \
        learn learn-off _learn-apply learned \
        keygen rotate-signing-key install-hooks prune prune-build prune-dind \
        certificates cert renew-certs \
        clean clean-dind \
        distclean reload-egress reload-images reload-ingress ps logs denied df \
        _project-egress

help: ## Show this help
	@echo "Setup:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Setup:'        | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "Workspaces  (per-project profiles — docs/workspaces.md, docs/github.md):"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Workspaces:'  | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "GitHub:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'GitHub:'      | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "Run:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Run:'         | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "Egress:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Egress:'      | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "TLS / signing:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'TLS or signing:' | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "Inspect:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Inspect:'     | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'
	@echo
	@echo "Maintenance:"
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | grep 'Maintenance:' | awk -F':.*## ' '{sub(/^[A-Za-z ]+: /, "", $$2); printf "  %-20s %s\n", $$1, $$2}'

preflight: ## Setup: Check host prerequisites (runs automatically before build/start)
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

# Per-workspace egress additions — WRITTEN by scripts/workspace.sh on every
# `make workspace` switch; this rule only bootstraps an empty stub so the
# egress image builds for users who never touch workspaces (docs/workspaces.md).
egress/allowlist.workspace.txt:
	@printf '%s\n%s\n' \
	    '# Per-workspace egress additions — generated by scripts/workspace.sh.' \
	    '# Do not edit: put domains into workspaces/<name>.allowlist.txt instead.' > $@

# Per-workspace git-host scope (docs/github.md) — WRITTEN by
# scripts/workspace.sh when the merged config declares a GITHUB scope; this
# rule only bootstraps an empty stub (no scope) so the egress image builds.
egress/allowlist.git-scope.txt:
	@printf '%s\n%s\n' \
	    '# Git-host egress scope — generated by scripts/workspace.sh.' \
	    '# Do not edit: declare GITHUB_* in .secure-container/workspace.env instead.' > $@

# Project egress merge — RUNS UNCONDITIONALLY (a file rule with no
# prerequisites fires once and goes stale). The merge script only rewrites
# its target when the content changes, so the proxy layer cache stays warm.
# Consumed by egress-proxy builds; egress/allowlist.project.txt has no file
# rule because the script always materializes it (stub without a project).
_project-egress:
	@scripts/merge-project-allowlist.sh

# Bind-mount source for the dev CA's PUBLIC half. Must exist before any
# compose run, or the engine creates it root-owned; empty is fine (HTTPS
# support is simply off until `make certificates`).
secrets/dev-ca/public:
	@mkdir -p $@

# Bind-mount source for the 1h GitHub space token (docs/github.md). Same
# engine-would-create-it-root-owned hazard as above; empty = no token
# (scoped git/gh refuse until `make gh-token` or `make gh-renew`).
secrets/github-space:
	@mkdir -p $@

# Remote skill-sets cache (docs/skills.md) — bind source for
# /run/remote-skills; `make update-sandbox-skills` fills it (host git).
skills-remote:
	@mkdir -p $@

build: preflight egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Run: Build the sandbox images
	@scripts/renew-certs.sh --auto || true
	$(COMPOSE) build

up: preflight keygen egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Run: Start the sandbox in the background
	@scripts/renew-certs.sh --auto || true
	$(COMPOSE) up -d

down: ## Run: Stop the sandbox (incl. dind sidecars and the interactive session)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans

stop: ## Run: Stop containers but keep them (gentler than down; no removal)
	$(WARN_SESSION)
	$(COMPOSE_ALL) stop

restart: down up ## Run: Full restart — also drops the dind sidecar and with it every nested container

shell: preflight keygen egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Run: Interactive shell inside the sandbox
	$(call session,bash)

claude: preflight keygen egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Run: Run Claude Code interactively inside the sandbox
	$(call session,claude)

yolo: preflight keygen egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Run: Run Claude Code with --dangerously-skip-permissions (the point of this sandbox)
	$(call session,claude --dangerously-skip-permissions)

# --- workspaces ------------------------------------------------------------
# Named per-project profiles compiled into the generated .env — full guide:
# docs/workspaces.md. The script picks the cheapest apply path itself
# (nothing / reload-egress / restart / build+restart) and routes
# EGRESS=learning through make learn / learn-off.

workspaces: ## Workspaces: List workspace definitions (active one marked)
	@scripts/workspace.sh list

ws-prune: ## Workspaces: Remove definitions whose project folder is gone (FORCE=1 skips the prompt)
	@scripts/workspace.sh prune

ws-rm: ## Workspaces: Remove ONE definition: make ws-rm NAME=x (asks which if NAME is empty; FORCE=1 skips the prompt)
	@scripts/workspace.sh rm "$(if $(findstring command line,$(origin NAME)),$(NAME),)"

workspace: preflight ## Workspaces: Switch workspace: make workspace NAME=x (FORCE=1 overrides the edit guard)
	@if [ -z "$(NAME)" ]; then echo "workspace: NAME is required — make workspace NAME=x (a stray ambient NAME env var would otherwise leak in)"; exit 1; fi
	@scripts/workspace.sh switch "$(NAME)"

new-workspace: preflight ## Workspaces: Create a workspace definition: make new-workspace NAME=x
	@if [ -z "$(NAME)" ]; then echo "new-workspace: NAME is required — make new-workspace NAME=x"; exit 1; fi
	@scripts/workspace.sh new "$(NAME)"

add-workspace: preflight ## Workspaces: Register a repo-anchored workspace: make add-workspace PROJECT=~/projects/x [WS=custom-name]
	@if [ -z "$(PROJECT)" ]; then echo "add-workspace: PROJECT is required — make add-workspace PROJECT=~/projects/<repo>"; exit 1; fi
	@scripts/workspace.sh add "$(PROJECT)" "$(WS)"

gh-token: preflight secrets/github-space ## GitHub: Mint a 1h project-scoped GitHub token (human break-glass; hands it to local gh when present)
	@scripts/mint-github-token.sh mint || exit 1
	@if command -v gh >/dev/null 2>&1; then \
	    prev="$$(gh auth status --json 2>/dev/null | jq -r '.hosts["github.com"].users[] | select(.active) | .login' 2>/dev/null || true)"; \
	    gh auth login --with-token < secrets/github-space/token; \
	    new="$$(gh auth status --json 2>/dev/null | jq -r '.hosts["github.com"].users[] | select(.active) | .login' 2>/dev/null || true)"; \
	    if [ -n "$$prev" ] && [ "$$prev" != "$$new" ]; then \
	        gh auth switch -u "$$prev" >/dev/null 2>&1 \
	        && echo "gh auth: token installed as '$$new' — your active account '$$prev' restored (switch with: gh auth switch -u $$new)"; \
	    else \
	        echo "gh auth: token installed for this shell's gh config (expires in 1h)"; \
	    fi; \
	else \
	    echo "gh CLI not found in WSL — token written to secrets/github-space/token (expires in 1h)"; \
	    echo "Install gh (docs/github.md) for 'make gh-token' to install it automatically."; \
	fi

gh-renew: preflight secrets/github-space ## GitHub: Refresh the GitHub token every ~50min while a session runs (24-48h runs; stops itself after)
	@scripts/mint-github-token.sh renew

gh-app: preflight ## GitHub: Create + wire the per-project App (manifest flow; 2 browser clicks): make gh-app PROJECT=~/projects/x
	@scripts/gh-app-setup.sh "$(PROJECT)" "$(WS)"

gh-app-wire: preflight ## GitHub: Rescue/wire an app from an existing PEM: make gh-app-wire PROJECT=~/projects/x KEY=~/.config/.../app.pem
	@scripts/gh-app-setup.sh --wire "$(KEY)" "$(PROJECT)"

install-scc: preflight ## Setup: install the scc CLI for the current user (launcher ~/.local/bin/scc)
	@mkdir -p "$$HOME/.local/bin" \
	    && if [ -f "$$HOME/.local/bin/scc" ]; then \
	        old="$$(sed -n 's/.*exec bash "\([^"]*\)\/scripts\/scc.sh".*/\1/p' "$$HOME/.local/bin/scc")"; \
	        if [ -n "$$old" ] \
	           && [ "$$old/scripts/scc.sh" != "$(CURDIR)/scripts/scc.sh" ]; then \
	            echo "REPLACING previous launcher for: $$old"; \
	        elif [ -z "$$old" ]; then \
	            echo "NOTE: overwriting an existing ~/.local/bin/scc that is not an scc launcher"; \
	        fi; \
	    fi \
	    && rm -f "$$HOME/.local/bin/scc" \
	    && printf '#!/bin/sh\nexec bash "%s/scripts/scc.sh" "$$@"\n' "$(CURDIR)" \
	       > "$$HOME/.local/bin/scc" \
	    && chmod 0755 "$$HOME/.local/bin/scc" \
	    && echo "Installed scc -> ~/.local/bin/scc (launcher for $(CURDIR)/scripts/scc.sh)" \
	    && ( echo "$$PATH" | grep -q "$$HOME/.local/bin" || echo "NOTE: add ~/.local/bin to PATH to use 'scc' everywhere" )

# --- surgical reloads ------------------------------------------------------
# Apply a policy change WITHOUT tearing the sandbox down. `make restart`
# stops the dind sidecar too, which kills every nested container (Sail
# databases, mailpit, ...) — far too blunt for a one-line allowlist edit.

reload-egress: egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress ## Egress: Apply an egress allowlist edit (rebuilds only the proxy)
	$(COMPOSE) build egress-proxy
	$(COMPOSE) up -d --no-deps egress-proxy
	@echo "egress-proxy reloaded — running sessions kept; its denial log starts empty again."

reload-images: dind/images-allowlist.txt ## Egress: Apply a dind image-allowlist edit (recreates only the guard)
	$(COMPOSE_ALL) up -d --no-deps --force-recreate dind-guard
	@echo "dind-guard reloaded — the daemon and its containers kept running."

reload-ingress: ## Egress: Apply an ingress port/config change (recreates only the ingress)
	@$(COMPOSE) config --services | grep -qx ingress \
	    || { echo "no 'ingress' service — enable it in docker-compose.override.yml (see docker-compose.override.example.yml)"; exit 1; }
	$(COMPOSE) up -d --no-deps ingress

# --- egress learning mode --------------------------------------------------
# One open research pass that logs every contacted domain, then distills
# the minimal allowlist. NOT the hardened posture: doctor stays red while
# active, and sessions run WITHOUT the signing key (see docs/workflow.md).

learn: preflight ## Egress: Enter egress learning mode (open egress, logged; signing key removed)
	@scripts/confirm-learn.sh
	@touch .learning-mode
	@$(MAKE) --no-print-directory EGRESS_MODE=learning _learn-apply
	@echo
	@echo "LEARNING MODE ACTIVE — egress is OPEN (LAN + git hosts still denied)."
	@echo "  * Start a FRESH session (make claude/yolo) — it runs without the"
	@echo "    signing key; sessions started earlier still carry it: close them."
	@echo "  * Do not mount secret-bearing projects while this mode is on."
	@echo "  * Distill with 'make learned'; leave with 'make learn-off'."
	@echo "  * Full guide: docs/egress.md"

learn-off: ## Egress: Leave learning mode and rebake the proxy with the (updated) allowlist
	@rm -f .learning-mode
	@$(MAKE) --no-print-directory EGRESS_MODE=allowlist _learn-apply
	@echo
	@echo "Learning mode OFF — allowlist enforced again. Rerun the task to"
	@echo "verify the curated list is complete (blocked-domains catches gaps),"
	@echo "and run 'make doctor' to confirm the posture is green."

# Re-entered via $(MAKE) so the marker created/removed above is seen by a
# fresh Makefile evaluation (COMPOSE/EGRESS_MODE are computed at parse time).
_learn-apply: egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress
	$(COMPOSE) build egress-proxy
	$(COMPOSE) up -d --no-deps egress-proxy

learned: secrets/dev-ca/public ## Egress: Distill the domains used in learning mode into an allowlist block
	@$(COMPOSE) run --rm --no-deps -T claude-code learned-domains

keygen: ## Setup: Ensure the signing key exists (idempotent, host-side)
	@scripts/ensure-signing-key.sh

rotate-signing-key: ## TLS or signing: Rotate the signing key (interactive, host-side)
	@scripts/rotate-signing-key.sh

# --- local HTTPS (dev CA) --------------------------------------------------
# Host-only, name-constrained CA for .test project certs; the sandbox only
# ever sees the public cert and per-project 3-day leafs. Full guide and
# threat model: docs/https.md.

certificates: ## Setup: Create the local dev CA for project HTTPS (idempotent; prints trust steps)
	@scripts/ensure-dev-ca.sh --show-trust

cert: ## TLS or signing: Mint a 3-day HTTPS cert into <project>/certs: make cert DOMAIN=myapp.test [DIR=subdir]
	@[ -n "$(PROJECTS_DIR)" ] || { echo "cert: PROJECTS_DIR is not set — configure .env first."; exit 1; }
	@scripts/ensure-dev-ca.sh
	@scripts/mint-cert.sh "$(DOMAIN)" "$(PROJECTS_DIR)$(if $(DIR),/$(DIR),)/certs"

renew-certs: ## TLS or signing: Re-mint every dev-CA project cert with a fresh 3-day validity
	@scripts/renew-certs.sh

doctor: preflight keygen egress/allowlist.txt egress/allowlist.workspace.txt egress/allowlist.git-scope.txt _project-egress dind/images-allowlist.txt secrets/dev-ca/public secrets/github-space skills-remote ## Inspect: Run the full hardening self-test (host + container)
	@scripts/doctor.sh --host

status: ## Inspect: Per-project feedback for a folder (onboarded? registered? running?) — make status [PROJECT=~/x]
	@scripts/status.sh "$(PROJECT)"

install-hooks: ## Setup: Install the secret-blocking pre-commit hook into THIS repo
	install -m 0755 security/pre-commit .git/hooks/pre-commit
	@echo "Installed security/pre-commit -> .git/hooks/pre-commit"

ps: ## Inspect: Show sandbox containers — outer AND the ones nested inside dind
	@$(COMPOSE_ALL) ps
	@cid=$$($(COMPOSE_ALL) ps -q dind-daemon 2>/dev/null); \
	 if [ -n "$$cid" ]; then \
	     echo; echo "=== nested inside dind (invisible to the host's docker ps) ==="; \
	     $(ENGINE) exec "$$cid" docker -H tcp://127.0.0.1:2375 ps -a; \
	 fi

logs: ## Inspect: Follow the sandbox logs (proxy denials, dind, ingress)
	$(COMPOSE_ALL) logs -f --tail=100

denied: preflight secrets/dev-ca/public ## Egress: List domains the egress proxy denied since its last restart
	@$(COMPOSE) run --rm -T claude-code blocked-domains

df: ## Inspect: Show disk usage of the host engine AND of the nested dind daemon
	@echo "=== host engine ==="
	@$(ENGINE) system df
	@cid=$$($(COMPOSE_ALL) ps -q dind-daemon 2>/dev/null); \
	 if [ -n "$$cid" ]; then \
	     echo; echo "=== dind sidecar (all of it inside the dind-storage volume) ==="; \
	     $(ENGINE) exec "$$cid" docker -H tcp://127.0.0.1:2375 system df; \
	 fi

prune: ## Maintenance: Reclaim disk space from dangling images (safe: untagged layers only)
	$(ENGINE) image prune -f

prune-build: ## Maintenance: Reclaim the host build cache (safe; only makes the next build slower)
	$(ENGINE) builder prune -f

prune-dind: ## Maintenance: Reclaim disk INSIDE dind (stopped containers, dangling images, build cache)
	@$(DIND_EXEC) system prune -f

clean: ## Maintenance: Remove containers and locally built images (keeps volumes & secrets)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans --rmi local

clean-dind: ## Maintenance: Drop the dind image/layer storage (keeps your Claude login)
	$(WARN_SESSION)
	$(COMPOSE_ALL) rm -sf dind-daemon dind-guard
	$(ENGINE) volume rm claude-sandbox_dind-storage

distclean: ## Maintenance: Also remove ALL volumes (logs you out of Claude, drops dind storage)
	$(WARN_SESSION)
	$(COMPOSE_ALL) down --remove-orphans --rmi local --volumes

update-sandbox-skills: preflight skills-remote ## Skill-sets: refresh remote skills for the container (docs/skills.md)
	@scripts/sync-sandbox-skills.sh
