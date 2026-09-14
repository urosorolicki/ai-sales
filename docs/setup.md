# Setup

Target: a Mac Mini running 24/7 at home. Everything below also works on any
Linux host with Docker.

## Requirements

| | |
|---|---|
| Hardware | Mac Mini (Apple silicon recommended), 16 GB RAM minimum if Ollama runs locally, 100 GB free disk |
| Software | Docker Desktop (or Colima), `make`, `git`, `openssl`, optionally `gpg` for encrypted backups |
| Network | Outbound HTTPS. Inbound only if n8n is to be reachable from outside - see Exposure below. |

Check before starting:

```bash
docker --version
docker compose version
make --version
```

## First run

```bash
git clone <your-repo-url> ai-sales-machine
cd ai-sales-machine

make init          # creates .env and Caddyfile, generates all secrets
```

`make init` generates `POSTGRES_PASSWORD`, `REDIS_PASSWORD`,
`N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_PASSWORD` and `BACKUP_PASSPHRASE`. It
never overwrites an existing `.env`.

Then edit `.env` and fill in what cannot be generated:

| Variable | Needed for |
|---|---|
| `LLM_API_KEY` | Everything. The research, scoring, outreach and conversation agents. |
| `N8N_HOST`, `CADDY_DOMAIN`, `WEBHOOK_URL` | Only once a real domain exists. The placeholders are fine locally. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Phase 3 |
| `APOLLO_API_KEY` | Phase 4 |
| `EMAIL_*`, `SMTP_*`, `IMAP_*` | Phase 7 and 8 |

**Back up `N8N_ENCRYPTION_KEY` now, somewhere outside this machine.** Every
credential stored inside n8n is encrypted with it. Lose it and every credential
has to be re-entered by hand.

Then:

```bash
make up            # start the stack
make migrate       # apply database migrations
make pull-model    # pull the local Ollama model (several GB, takes a while)
make health        # verify everything
```

`make health` should end with `healthy`. If it does not, it names what failed.

## Verify

```bash
make ps                    # all five containers up
make migrate-status        # every migration applied, 0 pending
make db                    # psql shell; \dt should list 8 tables
```

Optionally load demo rows to exercise the schema and the workflows:

```bash
make seed-demo             # example.org only, never run against real data
```

n8n is at `http://localhost:5678`, behind basic auth. The username and password
are `N8N_BASIC_AUTH_USER` and `N8N_BASIC_AUTH_PASSWORD` in `.env`.

## Ollama on macOS: read this

The Ollama container cannot use the Mac's GPU. Docker on macOS runs in a Linux
VM with no Metal passthrough, so the containerised Ollama is CPU-only and will
be several times slower than the native app.

Two options:

**Containerised (default).** Works out of the box, no host dependency, slow.
Fine for classification, which is short and low volume.

**Native (recommended on a Mac Mini).** Install Ollama on macOS, then in `.env`:

```
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

and stop the container:

```bash
docker compose stop ollama
```

The native app must be configured to listen on all interfaces
(`OLLAMA_HOST=0.0.0.0`) for the containers to reach it. Everything else is
unchanged - only the URL differs.

## Exposure

By default nothing is reachable from outside the machine. PostgreSQL, Redis,
Ollama and n8n all bind to `127.0.0.1`. Caddy publishes 80 and 443 but the
example config only serves `localhost` until a real domain is configured.

n8n needs to be reachable from the internet only when it must receive webhooks
(a Telegram webhook, or an email provider's inbound webhook). Polling avoids
this entirely and is the right first choice.

When inbound access is genuinely needed, in order of preference:

1. **Cloudflare Tunnel.** No inbound port, works behind CGNAT, which most home
   ISPs now use. This is the correct answer for a machine at home.
2. **Port forwarding plus Caddy with a real domain.** Only if the connection has
   a routable public address and the router is under your control.

Never expose PostgreSQL, Redis or Ollama. See `docs/security.md`.

## Day-to-day

```bash
make ps                    # status
make logs SERVICE=n8n      # follow one service
make health                # full check
make backup                # encrypted database dump
make restart SERVICE=n8n   # restart one service
make down                  # stop, keep all data
```

## Keeping it running

The Mac Mini needs three settings, and none of them are Docker's:

- **System Settings > Energy:** prevent automatic sleeping when the display is
  off, and start up again after a power failure.
- **Docker Desktop > General:** start Docker Desktop when you log in.
- **Auto-login,** or the containers will not start after a reboot until someone
  logs in.

`restart: unless-stopped` handles container crashes. It does not handle a host
that went to sleep.

Cron entries worth having:

```cron
0 3 * * *  cd /path/to/ai-sales-machine && make backup >> logs/backup.log 2>&1
*/30 * * * * cd /path/to/ai-sales-machine && ./scripts/healthcheck.sh --quiet || echo "unhealthy"
```

## Upgrades

Image versions are pinned in `.env`. To upgrade:

```bash
make backup
# edit the version in .env
docker compose pull
make up
make migrate
make health
```

Upgrade one component at a time. n8n in particular has had migrations between
minor versions that are not reversible - the backup before the pull is not
optional.

## Restore

```bash
gpg --decrypt backups/aisales-<timestamp>.dump.gpg > restore.dump
docker exec -i aisales-postgres pg_restore -U aisales -d aisales \
    --clean --if-exists < restore.dump
```

This restores workflows and n8n credentials as well, because n8n stores both in
the same database. The credentials are only usable with the matching
`N8N_ENCRYPTION_KEY`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make up` fails on a missing variable | Empty required value in `.env` | The error names the variable. Fill it in. |
| n8n restarts repeatedly | Wrong `N8N_ENCRYPTION_KEY` for an existing volume | Restore the original key. A new key cannot decrypt stored credentials. |
| n8n cannot reach the database | The `n8n` schema does not exist | It is created by `infra/docker/postgres/initdb`, which only runs on a fresh volume. Create it by hand: `CREATE SCHEMA n8n;` |
| `make migrate` says the container is not running | Stack is down | `make up` first. |
| migrate reports DRIFT | An applied migration was edited | Never edit an applied migration. Revert the file and add a new one. |
| Ollama very slow | Containerised on macOS, CPU only | Switch to the native app as described above. |
| Caddy cannot get a certificate | DNS does not point here, or 80/443 are not reachable | Use the staging ACME endpoint while testing, and check the DNS record. |
