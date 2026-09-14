#!/usr/bin/env bash
#
# Apply postgres/migrations/*.sql in order, exactly once each.
#
# Runs psql inside the postgres container, so no local client is needed.
# Each migration runs in a single transaction: it either applies completely
# and is recorded in schema_migrations, or nothing changes.
#
#   ./infra/scripts/migrate.sh            apply pending migrations
#   ./infra/scripts/migrate.sh --status   show applied vs pending
#   ./infra/scripts/migrate.sh --check    exit 1 if anything is pending

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MIGRATIONS_DIR="postgres/migrations"
CONTAINER="${POSTGRES_CONTAINER:-aisales-postgres}"

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER not set - copy .env.example to .env}"
: "${POSTGRES_DB:?POSTGRES_DB not set - copy .env.example to .env}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "error: container '$CONTAINER' is not running. Run 'make up' first." >&2
    exit 1
fi

psql_run() {
    docker exec -i "$CONTAINER" \
        psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

psql_value() {
    psql_run -tAc "$1"
}

checksum_of() {
    # sha256 of the file contents, used to detect edits to applied migrations.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

ensure_ledger() {
    psql_run -c "CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY,
        checksum text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now());" >/dev/null
}

# No mapfile here: macOS still ships bash 3.2 and this must run on the Mac Mini.
MIGRATIONS=()
while IFS= read -r line; do
    MIGRATIONS+=("$line")
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -name "*.sql" | sort)

if [[ ${#MIGRATIONS[@]} -eq 0 ]]; then
    echo "error: no migrations found in $MIGRATIONS_DIR" >&2
    exit 1
fi

ensure_ledger

MODE="apply"
case "${1:-}" in
    --status) MODE="status" ;;
    --check)  MODE="check" ;;
    "")       MODE="apply" ;;
    *) echo "usage: $0 [--status|--check]" >&2; exit 2 ;;
esac

pending=0
drift=0

for file in "${MIGRATIONS[@]}"; do
    version="$(basename "$file" .sql)"
    checksum="$(checksum_of "$file")"
    recorded="$(psql_value "SELECT checksum FROM schema_migrations WHERE version = '$version';")"

    if [[ -n "$recorded" ]]; then
        if [[ "$recorded" != "$checksum" ]]; then
            echo "DRIFT    $version (applied copy differs from the file on disk)"
            drift=1
        elif [[ "$MODE" == "status" ]]; then
            echo "applied  $version"
        fi
        continue
    fi

    pending=$((pending + 1))

    if [[ "$MODE" != "apply" ]]; then
        echo "pending  $version"
        continue
    fi

    echo "applying $version"
    docker exec -i "$CONTAINER" \
        psql -v ON_ERROR_STOP=1 -q --single-transaction \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$file"
    psql_run -c "INSERT INTO schema_migrations (version, checksum)
                 VALUES ('$version', '$checksum');" >/dev/null
done

if [[ $drift -eq 1 ]]; then
    echo
    echo "error: an already-applied migration was edited." >&2
    echo "       Never edit an applied migration - add a new one instead." >&2
    exit 1
fi

case "$MODE" in
    check)
        if [[ $pending -gt 0 ]]; then
            echo "$pending migration(s) pending"
            exit 1
        fi
        echo "database is up to date"
        ;;
    status)
        echo "$pending pending"
        ;;
    apply)
        if [[ $pending -eq 0 ]]; then
            echo "nothing to apply - database is up to date"
        else
            echo "applied $pending migration(s)"
        fi
        ;;
esac
