# Security

This system holds an API key that costs money, a mailbox that can send on your
behalf, and personal data about people who never asked to be in it. All three
deserve more care than a side project usually gets.

## Secrets

**Never commit a secret.** `.env` is gitignored, `.env.example` contains only
empty values, and `make secrets-scan` fails the build if anything
credential-shaped appears in a tracked file. Run it before every commit.

**Every secret comes from `.env`.** Nothing is hardcoded in
`docker-compose.yml`, the SQL, the prompts or the workflows. The compose file
uses `${VAR:?message}` for required values, so a missing secret fails at start
with a clear message instead of silently defaulting.

**`.env` is chmod 600.** `make init` sets it; `make health` warns if it drifts.

**`N8N_ENCRYPTION_KEY` is the master key.** Every credential stored in n8n is
encrypted with it. Back it up separately from the database dumps, because a
dump plus the key in the same place is the same as no encryption. Rotating it
invalidates every stored credential.

**Credentials belong in n8n's credential store,** not in workflow node
parameters and not in environment variables read by expressions. n8n encrypts
the credential store; exported workflow JSON does not contain credential values,
which is what makes `n8n/workflows/` safe to commit.

**API keys must never reach a log.** Do not log full request objects. WF-99
alert text is built from specific fields, never from a whole error payload -
provider errors routinely echo the request headers back.

## Network exposure

| Service | Binding | Public |
|---|---|---|
| PostgreSQL | `127.0.0.1:5432` | Never |
| Redis | `127.0.0.1:6379` | Never |
| Ollama | `*:11434` on the host | Never through Caddy |
| n8n | `127.0.0.1:5678` | Only through Caddy, with TLS and auth |
| Caddy | `0.0.0.0:80,443` | Yes, when a domain is configured |

**Ollama runs on the host and binds every interface,** which is how the n8n
container reaches it and also means the local network can. On a home network
behind NAT that is usually acceptable; elsewhere bind it to the Docker bridge
address instead. See `docs/ollama.md`.

**Ollama has no authentication of any kind.** Anyone who can reach port 11434
can use the model, read what is sent to it, and consume the machine's CPU. It
must never be published beyond loopback.

**Redis has a password but no TLS.** It is on the internal Docker network. A
published Redis port is one of the most reliably exploited services on the
internet.

**Note on Docker and host firewalls:** published ports are inserted into the
`DOCKER` chain, which is evaluated before the host firewall's input rules on
Linux. A `ufw deny` will not close a published Docker port. This is why the
bindings above are explicit loopback addresses rather than a firewall rule.

**n8n must never be exposed without both TLS and authentication.** It stores
credentials and can execute arbitrary code. `N8N_BASIC_AUTH_ACTIVE=true` is the
minimum, and it is only meaningful over HTTPS.

**Cloudflare Tunnel is the right answer for a home connection.** No inbound
port, no dependency on the ISP's address, works behind CGNAT, and terminates
TLS before anything reaches the house.

## Data

The database holds names, job titles, email addresses and notes about people at
companies who did not opt in. Under GDPR this is processing personal data for
direct marketing, which is permitted under legitimate interest for B2B contact
in most of the EU, but carries obligations:

- **An unconditional right to object.** The suppression list is that mechanism,
  and it must work the first time, every time.
- **Every message identifies the sender** and explains how to stop receiving
  them. This is a legal requirement, not a courtesy.
- **Data minimisation.** Store what is needed to decide whether to write and
  what to write. Not more.
- **Erasure on request.** A person asking to be deleted gets deleted, with a
  suppression entry left behind so the pipeline does not rediscover them.

This is a description of the obligations the system is built to meet, not legal
advice. Rules differ by country and the operator is responsible for their own.

## Suppression

The suppression list is the one rule the system enforces in three places:

1. **Discovery** skips suppressed domains, so they never enter the pipeline.
2. **The dispatcher** checks before every send.
3. **A database trigger** on `outreach` rejects the insert outright.

The third one exists because the first two are code, and code has bugs. A
workflow that forgets the check gets a failed transaction, not a sent email.

Additions to the list are permanent. There is no removal path in the workflows
by design; taking someone off requires a deliberate manual action.

## Outreach volume

Rate limits are a security control here, not a politeness setting. A
compromised or misconfigured pipeline that sends a thousand emails destroys the
sending domain permanently, and there is no recovery.

| Control | Variable | Default |
|---|---|---|
| Global pause | `OUTREACH_PAUSED` | `true` |
| Automatic sending | `OUTREACH_AUTOSEND_ENABLED` | `false` |
| Messages per day | `OUTREACH_DAILY_LIMIT` | 20 |
| Messages per domain | `OUTREACH_PER_DOMAIN_LIMIT` | 1 |
| Minimum score to contact | `OUTREACH_MIN_SCORE` | 60 |
| Maximum follow-ups | `OUTREACH_FOLLOWUP_MAX` | 2 |

`OUTREACH_PAUSED` is checked by WF-06 on every run, before anything else. It is
the stop button, and it must stay a single boolean that a person can flip from
their phone without thinking.

Start well below the limits. Twenty a day from a new domain is already
aggressive; five is a better first week.

## Backups

`make backup` writes a compressed `pg_dump` and encrypts it with GPG AES256
using `BACKUP_PASSPHRASE`. Backups are chmod 600 in a chmod 700 directory, and
pruned after `BACKUP_RETENTION_DAYS`.

A database dump contains every prospect's personal data and every conversation.
Treat a backup file exactly like the database:

- Never copy one to cloud storage unencrypted.
- Keep `BACKUP_PASSPHRASE` and `N8N_ENCRYPTION_KEY` somewhere that is not the
  machine being backed up, and not the same place as the backups.
- Test a restore at least once. An untested backup is a belief, not a backup.

## Prompt injection

Research reads pages written by other people, and the classifier reads email
written by strangers. Both are untrusted input reaching a model.

- Treat all fetched content and all inbound email as data, never as
  instructions. The prompts state this; the workflows must not concatenate
  fetched text into a position where it can be read as a directive.
- The agents have no tools. They return JSON that is validated against a schema
  before anything is written. A model that has been talked into something can
  produce a bad row; it cannot execute anything.
- The conversation agent's hard limits are checked in the workflow after the
  model returns, not only in the prompt. A prompt is a request; a check is a
  control.
- Nothing an agent returns is ever used to build SQL, a shell command or a URL
  to fetch.

## Checklist before going live

- [ ] `make secrets-scan` is clean
- [ ] `.env` is chmod 600 and not tracked
- [ ] `N8N_ENCRYPTION_KEY` is backed up off the machine
- [ ] `BACKUP_PASSPHRASE` is set and stored separately
- [ ] A restore has been tested at least once
- [ ] Own domain and current clients are in `suppression_list`
- [ ] n8n is not reachable without TLS and authentication
- [ ] PostgreSQL and Redis are on loopback only; Ollama is not reachable from outside the LAN
- [ ] Daily and per-domain limits are set low
- [ ] `OUTREACH_PAUSED=true` until a batch has been read by a human
- [ ] Every outreach template identifies the sender and how to opt out
