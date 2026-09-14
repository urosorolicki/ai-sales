#!/usr/bin/env bash
#
# Refuse to let a credential reach git. Checks tracked files (or the whole
# working tree when the repo has no commits yet) for the shapes of secrets
# this project actually handles.
#
#   ./infra/scripts/secrets-scan.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

FINDINGS=0

if git rev-parse --git-dir >/dev/null 2>&1; then
    FILES="$(git ls-files 2>/dev/null)"
    [[ -z "$FILES" ]] && FILES="$(find . -type f -not -path './.git/*' -not -path './backups/*')"
else
    FILES="$(find . -type f -not -path './.git/*' -not -path './backups/*')"
fi

report() {
    echo "  $1"
    FINDINGS=$((FINDINGS + 1))
}

echo "==> files that must never be tracked"
for forbidden in .env Caddyfile; do
    if echo "$FILES" | grep -qx "./$forbidden" || echo "$FILES" | grep -qx "$forbidden"; then
        report "$forbidden is tracked or present in the scan set - it must be gitignored"
    fi
done
echo "$FILES" | grep -E '\.(key|pem|p12|pfx)$' | while read -r f; do
    echo "  key material tracked: $f"
done

echo "==> credential-shaped strings"
PATTERNS=(
    'sk-[A-Za-z0-9]{20,}'
    'sk-ant-[A-Za-z0-9_-]{20,}'
    'ghp_[A-Za-z0-9]{20,}'
    'AKIA[0-9A-Z]{16}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)
for pat in "${PATTERNS[@]}"; do
    hits="$(echo "$FILES" | xargs -I{} grep -HnE "$pat" {} 2>/dev/null \
        | grep -v 'infra/scripts/secrets-scan.sh')"
    if [[ -n "$hits" ]]; then
        echo "$hits" | while read -r line; do report "$line"; done
        FINDINGS=$((FINDINGS + 1))
    fi
done

echo "==> non-empty secret assignments outside .env"
ASSIGN='^(POSTGRES_PASSWORD|REDIS_PASSWORD|N8N_ENCRYPTION_KEY|N8N_BASIC_AUTH_PASSWORD|LLM_API_KEY|APOLLO_API_KEY|TELEGRAM_BOT_TOKEN|EMAIL_API_KEY|SMTP_PASSWORD|IMAP_PASSWORD|BACKUP_PASSPHRASE)=.+'
hits="$(echo "$FILES" | grep -vE '(^|/)\.env$' | xargs -I{} grep -HnE "$ASSIGN" {} 2>/dev/null \
    | grep -v 'infra/scripts/secrets-scan.sh')"
if [[ -n "$hits" ]]; then
    echo "$hits" | while read -r line; do report "$line"; done
    FINDINGS=$((FINDINGS + 1))
fi

echo
if [[ $FINDINGS -eq 0 ]]; then
    echo "clean - no secrets found in tracked files"
    exit 0
fi
echo "$FINDINGS potential secret(s) found. Do not commit."
exit 1
