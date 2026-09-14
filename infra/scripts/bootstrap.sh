#!/usr/bin/env bash
#
# First-run setup: create .env and Caddyfile from the committed templates and
# fill in the values that must be random. Never overwrites an existing .env.
#
#   ./infra/scripts/bootstrap.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "${1:-24}"
    else
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c $(( ${1:-24} * 2 ))
        echo
    fi
}

set_var() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file"; then
        # Portable in-place edit: BSD sed on macOS needs the -i argument.
        sed "s|^${key}=.*|${key}=${value}|" "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

if [[ -f .env ]]; then
    echo ".env already exists - leaving it untouched."
else
    cp .env.example .env
    chmod 600 .env
    echo "created .env from .env.example"

    set_var POSTGRES_PASSWORD        "$(gen_secret 24)" .env
    set_var REDIS_PASSWORD           "$(gen_secret 24)" .env
    set_var N8N_ENCRYPTION_KEY       "$(gen_secret 32)" .env
    set_var N8N_BASIC_AUTH_PASSWORD  "$(gen_secret 16)" .env
    set_var BACKUP_PASSPHRASE        "$(gen_secret 24)" .env
    echo "generated: POSTGRES_PASSWORD, REDIS_PASSWORD, N8N_ENCRYPTION_KEY,"
    echo "           N8N_BASIC_AUTH_PASSWORD, BACKUP_PASSPHRASE"
fi

if [[ -f Caddyfile ]]; then
    echo "Caddyfile already exists - leaving it untouched."
else
    cp Caddyfile.example Caddyfile
    echo "created Caddyfile from Caddyfile.example"
fi

mkdir -p backups
chmod 700 backups

cat <<'NEXT'

Next steps:
  1. Edit .env and fill in the values bootstrap cannot generate:
       LLM_API_KEY          required
       N8N_HOST / CADDY_DOMAIN / WEBHOOK_URL   once a real domain exists
       TELEGRAM_BOT_TOKEN, APOLLO_API_KEY, EMAIL_*   later phases
  2. Back up N8N_ENCRYPTION_KEY somewhere safe. Losing it makes every
     credential stored in n8n unrecoverable.
  3. make up
  4. make migrate
  5. make health
NEXT
