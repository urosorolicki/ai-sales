# ai-sales-machine
#
# Every target here is safe to run twice. The two that destroy data
# (clean, db-reset) refuse to run without CONFIRM=yes.

SHELL := /bin/bash
COMPOSE := docker compose
ENV_FILE := .env

.DEFAULT_GOAL := help

.PHONY: help init up down restart logs ps config validate health \
	    migrate migrate-status seed-demo db db-reset redis \
	    pull-model backup restore-help shell-n8n secrets-scan clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	    | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

$(ENV_FILE):
	@echo "No .env found. Run 'make init' first." && exit 1

init: ## Create .env and Caddyfile from templates, generate secrets
	@./infra/scripts/bootstrap.sh

up: $(ENV_FILE) ## Start the whole stack
	$(COMPOSE) up -d
	@echo
	@echo "Stack starting. Check with: make ps / make health"

down: ## Stop the stack, keep all data
	$(COMPOSE) down

restart: ## Restart the stack (or one service: make restart SERVICE=n8n)
	$(COMPOSE) restart $(SERVICE)

logs: ## Follow logs (or one service: make logs SERVICE=n8n)
	$(COMPOSE) logs -f --tail=200 $(SERVICE)

ps: ## Show container status
	$(COMPOSE) ps

config: $(ENV_FILE) ## Render and validate the resolved compose configuration
	$(COMPOSE) config

validate: ## Validate compose syntax and shell scripts without starting anything
	@echo "==> docker compose config"
	@tmp=$$(mktemp); 	 sed -e 's/^POSTGRES_PASSWORD=$$/POSTGRES_PASSWORD=validate/' 	     -e 's/^REDIS_PASSWORD=$$/REDIS_PASSWORD=validate/' 	     -e 's/^N8N_ENCRYPTION_KEY=$$/N8N_ENCRYPTION_KEY=validate/' 	     -e 's/^N8N_BASIC_AUTH_PASSWORD=$$/N8N_BASIC_AUTH_PASSWORD=validate/' 	     .env.example > $$tmp; 	 $(COMPOSE) --env-file $$tmp config -q && echo "    compose OK"; 	 rc=$$?; rm -f $$tmp; exit $$rc
	@echo "==> shell scripts"
	@for f in scripts/*.sh infra/scripts/*.sh; do bash -n "$$f" && echo "    $$f OK"; done
	@echo "==> n8n workflows"
	@python3 infra/scripts/validate-workflows.py

health: ## Run the full stack health check
	@./scripts/healthcheck.sh

migrate: $(ENV_FILE) ## Apply pending database migrations
	@./infra/scripts/migrate.sh

migrate-status: $(ENV_FILE) ## Show applied and pending migrations
	@./infra/scripts/migrate.sh --status

seed-demo: $(ENV_FILE) ## Load demo rows (example domains only, never in production)
	@echo "Loading postgres/seeds/0002_demo_data.sql"
	@docker exec -i aisales-postgres psql -v ON_ERROR_STOP=1 -q \
	    -U "$$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2)" \
	    -d "$$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2)" \
	    < postgres/seeds/0002_demo_data.sql
	@echo "done"

db: $(ENV_FILE) ## Open a psql shell on the application database
	@docker exec -it aisales-postgres psql \
	    -U "$$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2)" \
	    -d "$$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2)"

redis: $(ENV_FILE) ## Open a redis-cli shell
	@docker exec -it aisales-redis sh -c 'redis-cli -a "$$REDIS_PASSWORD" --no-auth-warning'

shell-n8n: ## Open a shell inside the n8n container
	@docker exec -it aisales-n8n /bin/sh

pull-model: $(ENV_FILE) ## Pull the local Ollama model named in .env
	@ollama pull "$$(grep -E '^OLLAMA_MODEL=' .env | cut -d= -f2)"

backup: $(ENV_FILE) ## Dump the database to $BACKUP_DIR (encrypted if configured)
	@./scripts/backup.sh

restore-help: ## Print the restore procedure
	@sed -n '1,30p' scripts/backup.sh | grep -E '^#' | sed 's/^# \{0,1\}//'

secrets-scan: ## Fail if anything that looks like a credential is tracked by git
	@./infra/scripts/secrets-scan.sh

db-reset: ## DESTRUCTIVE: drop and recreate the schema. Needs CONFIRM=yes
ifneq ($(CONFIRM),yes)
	@echo "Refusing to run. This drops every table in the application schema."
	@echo "If you are sure: make db-reset CONFIRM=yes"
	@exit 1
endif
	@docker exec -i aisales-postgres psql -v ON_ERROR_STOP=1 \
	    -U "$$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2)" \
	    -d "$$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2)" \
	    -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	@$(MAKE) migrate

clean: ## DESTRUCTIVE: remove containers AND all volumes. Needs CONFIRM=yes
ifneq ($(CONFIRM),yes)
	@echo "Refusing to run. This deletes the database, n8n workflows,"
	@echo "n8n credentials and every downloaded Ollama model."
	@echo "Take a backup first: make backup"
	@echo "If you are sure: make clean CONFIRM=yes"
	@exit 1
endif
	$(COMPOSE) down -v --remove-orphans
	@echo "volumes removed"
