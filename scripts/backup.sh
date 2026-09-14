#!/usr/bin/env bash
#
# Back up the PostgreSQL database (application schema + the n8n schema, which
# is where n8n stores workflows and credentials).
#
# Credentials inside n8n are encrypted with N8N_ENCRYPTION_KEY. A dump is
# useless without that key, so back the key up separately and securely - it is
# NOT included here on purpose.
#
#   ./scripts/backup.sh                 write an encrypted dump to $BACKUP_DIR
#   ./scripts/backup.sh --no-encrypt    plaintext dump (local disk only)
#   ./scripts/backup.sh --list          list existing backups
#
# Restore (destructive, do it deliberately):
#   gpg --decrypt aisales-<ts>.dump.gpg > restore.dump
#   docker exec -i aisales-postgres pg_restore -U "$POSTGRES_USER" \
#       -d "$POSTGRES_DB" --clean --if-exists < restore.dump

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER not set}"
: "${POSTGRES_DB:?POSTGRES_DB not set}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
CONTAINER="${POSTGRES_CONTAINER:-aisales-postgres}"
ENCRYPT=1

case "${1:-}" in
    --no-encrypt) ENCRYPT=0 ;;
    --list)
        ls -lh "$BACKUP_DIR" 2>/dev/null || echo "no backups in $BACKUP_DIR"
        exit 0
        ;;
    "") ;;
    *) echo "usage: $0 [--no-encrypt|--list]" >&2; exit 2 ;;
esac

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "error: container '$CONTAINER' is not running" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="$BACKUP_DIR/aisales-$STAMP.dump"

echo "dumping $POSTGRES_DB -> $TARGET"
docker exec "$CONTAINER" pg_dump \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --format=custom --compress=9 --no-owner --no-privileges \
    > "$TARGET"

if [[ ! -s "$TARGET" ]]; then
    echo "error: dump is empty, removing" >&2
    rm -f "$TARGET"
    exit 1
fi

if [[ $ENCRYPT -eq 1 ]]; then
    if [[ -z "${BACKUP_PASSPHRASE:-}" ]]; then
        echo "warning: BACKUP_PASSPHRASE is empty - leaving the dump unencrypted."
        echo "         Set it in .env before copying backups off this machine."
    elif ! command -v gpg >/dev/null 2>&1; then
        echo "warning: gpg not installed - leaving the dump unencrypted."
    else
        echo "encrypting"
        printf '%s' "$BACKUP_PASSPHRASE" | gpg --batch --yes --quiet \
            --symmetric --cipher-algo AES256 \
            --passphrase-fd 0 \
            --output "$TARGET.gpg" "$TARGET"
        rm -f "$TARGET"
        TARGET="$TARGET.gpg"
    fi
fi

chmod 600 "$TARGET"
echo "wrote $TARGET ($(du -h "$TARGET" | cut -f1))"

echo "pruning backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'aisales-*.dump*' \
    -mtime "+${RETENTION_DAYS}" -print -delete

echo "done"
