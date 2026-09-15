#!/usr/bin/env bash
#
# Read-only health check for the whole stack. Exits 0 if everything a workflow
# depends on is reachable, 1 otherwise. Safe to run from cron or Telegram.
#
#   ./scripts/healthcheck.sh
#   ./scripts/healthcheck.sh --quiet    only print failures

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

FAILURES=0

ok()   { [[ $QUIET -eq 1 ]] || printf '  OK    %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

section() { [[ $QUIET -eq 1 ]] || printf '\n%s\n' "$1"; }

check_container() {
    local name="$1"
    local state health
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)"
    if [[ -z "$state" ]]; then
        fail "$name: container does not exist"
        return
    fi
    if [[ "$state" != "running" ]]; then
        fail "$name: state=$state"
        return
    fi
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)"
    case "$health" in
        healthy)   ok   "$name: running, healthy" ;;
        none)      ok   "$name: running (no healthcheck)" ;;
        starting)  warn "$name: running, health starting" ;;
        *)         fail "$name: running, health=$health" ;;
    esac
}

section "Containers"
if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI not found"
else
    for c in aisales-postgres aisales-redis aisales-n8n aisales-caddy; do
        check_container "$c"
    done
fi

section "PostgreSQL"
if docker exec aisales-postgres pg_isready -q -U "${POSTGRES_USER:-aisales}" -d "${POSTGRES_DB:-aisales}" >/dev/null 2>&1; then
    ok "accepting connections"
    tables="$(docker exec aisales-postgres psql -tAqc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" \
        -U "${POSTGRES_USER:-aisales}" -d "${POSTGRES_DB:-aisales}" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${tables:-0}" -gt 0 ]]; then
        ok "public schema has ${tables} tables"
    else
        fail "public schema is empty - run 'make migrate'"
    fi
else
    fail "pg_isready failed"
fi

section "Redis"
if docker exec aisales-redis sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping' 2>/dev/null | grep -q PONG; then
    ok "PONG"
else
    fail "no PONG (wrong password or not ready)"
fi

section "n8n"
if docker exec aisales-n8n wget -q -O- http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    ok "healthz responding"
else
    fail "healthz not responding"
fi

section "Ollama"
# Ollama runs natively on the host, not in a container: a container on macOS gets
# no Metal access and would run on the CPU. It is checked over HTTP, and from
# inside n8n too, because that is the path that actually matters.
ollama_url="${OLLAMA_BASE_URL:-http://ollama:11434}"
if curl -fsS --max-time 5 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    models="$(curl -fsS --max-time 5 "http://127.0.0.1:11434/api/tags" 2>/dev/null \
        | tr ',' '\n' | grep -c '"name"' | tr -d '[:space:]')"
    if [[ "${models:-0}" -gt 0 ]]; then
        ok "reachable on the host, ${models} model(s) pulled"
    else
        warn "reachable but no models pulled - run 'make pull-model'"
    fi
    if docker exec aisales-n8n wget -q -O- --timeout=5 "${ollama_url}/api/tags" >/dev/null 2>&1; then
        ok "reachable from n8n at ${ollama_url}"
    else
        fail "n8n cannot reach ${ollama_url} - check the 'ollama:host-gateway' entry in docker-compose.yml"
    fi
else
    fail "not reachable on the host - is 'ollama serve' running? (brew services start ollama)"
fi

section "Disk"
avail="$(df -h . | awk 'NR==2 {print $4}')"
used_pct="$(df -h . | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [[ "${used_pct:-0}" -ge 90 ]]; then
    fail "filesystem ${used_pct}% used, ${avail} free"
else
    ok "${avail} free (${used_pct}% used)"
fi

section "Safety rails"
if [[ "${OUTREACH_AUTOSEND_ENABLED:-false}" == "true" ]]; then
    warn "OUTREACH_AUTOSEND_ENABLED=true - outreach sends without human approval"
else
    ok "autosend disabled (human approval required)"
fi
if [[ -f .env ]]; then
    perms="$(ls -l .env | cut -c1-10)"
    case "$perms" in
        -rw-------) ok ".env permissions $perms" ;;
        *)          warn ".env permissions $perms - run: chmod 600 .env" ;;
    esac
fi

printf '\n'
if [[ $FAILURES -eq 0 ]]; then
    echo "healthy"
    exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
