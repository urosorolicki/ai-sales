# ai-sales-machine

A self-hosted B2B sales pipeline for a senior DevOps/SRE consultant. It finds
companies with public evidence that they need infrastructure help, researches
them, scores them, drafts outreach, and - after a human approves it - sends,
watches for replies and manages the conversation.

It runs on one machine. A Mac Mini at home is the intended deployment.

**Phase 1: this repository is the foundation. Nothing is deployed and nothing
sends email yet.** See `docs/roadmap.md`.

---

## Why it exists

Consultants find clients through referrals and luck, and both are lumpy. The
alternative usually on offer is a lead database and a mail-merge, which puts the
same email in front of the same people as everyone else, and the recipients have
learned to delete it.

The premise here is different: **the useful signal is public.** A company that
posted a Senior DevOps Engineer role sixty days ago and wrote a blog post about
a Kubernetes migration last month has told you what they need, when they need
it, and in their own words. Systems rarely act on that because reading it at
scale is tedious, not because it is hard.

That is the job this system does. Everything else - the schema, the workflows,
the approval queue - exists to make that judgement repeatable and to stop it
from turning into spam.

## What it does

1. Discover companies that may need DevOps/SRE help
2. Detect buying signals: DevOps hiring, Kubernetes adoption, cloud migration,
   engineering growth, infrastructure scaling, reliability problems, cloud cost
   problems, new engineering leadership, funding followed by infra hiring
3. Research the company and its stack, separating facts from inference
4. Find the decision maker
5. Score the opportunity out of 100
6. Draft personalised outreach
7. Send it - **only after a human approves each message**
8. Watch for replies
9. Classify them
10. Continue the conversation automatically where it is safe to
11. Notify a human the moment it is not
12. Later: schedule meetings, and remember what worked

## Architecture

```
Caddy (TLS) -> n8n (orchestration) -> PostgreSQL (system of record)
                    |                  Redis (queue, rate limits)
                    |                  Ollama (local model, bulk work)
                    +--> external LLM, Apollo, SMTP/IMAP, Telegram
```

Five containers, no Kubernetes, no custom microservices. The hard problem is
scheduling and state, which n8n already solves; the intelligence is prompts and
JSON schemas, not a framework. Full reasoning in `docs/architecture.md`.

## Components

| Component | Role |
|---|---|
| PostgreSQL 16 | System of record. Enforces suppression, scoring bands and deduplication as constraints. |
| n8n | Orchestrator. Schedules, retries, credentials, audit trail. |
| Redis 7 | n8n queue, rate-limit counters, short-lived caches. |
| Ollama | Local model for high-volume, low-stakes work (reply classification). |
| External LLM | Research, scoring, outreach, conversation - where being wrong is expensive. |
| Caddy 2 | TLS and reverse proxy. |
| Telegram | The human interface: approvals, alerts, status. |
| Playwright | Fallback renderer for pages that need JavaScript. Not the default path. |

## Repository structure

```
ai-sales-machine/
├── docker-compose.yml        five services, pinned versions, healthchecks
├── Caddyfile.example         copy to Caddyfile, gitignored
├── .env.example              every variable, marked required or optional
├── Makefile                  make help
│
├── infra/
│   ├── docker/               redis.conf, postgres initdb
│   └── scripts/              bootstrap, migrate, secrets-scan
│
├── postgres/
│   ├── migrations/           0001-0010, applied once, checksummed
│   └── seeds/                suppression template, demo data
│
├── n8n/workflows/            exported workflow JSON
│
├── agents/                   per-agent contract: README + JSON Schema
│   ├── research/ scoring/ outreach/ classifier/ conversation/
│
├── prompts/                  the actual prompts, one per agent
│
├── docs/
│   ├── architecture.md       what it is and why
│   ├── setup.md              Mac Mini deployment, troubleshooting
│   ├── security.md           secrets, exposure, GDPR, rate limits
│   ├── workflows.md          all 13 workflows, inputs and outputs
│   ├── scoring.md            the 100-point rubric
│   ├── telegram.md           the human control plane
│   ├── opportunity-radar.md  the signal engine (Phase 13)
│   └── roadmap.md            14 phases
│
└── scripts/
    ├── healthcheck.sh
    └── backup.sh
```

## Local development

```bash
make init          # create .env and Caddyfile, generate secrets
# edit .env: LLM_API_KEY is the only one required to start
make up
make migrate
make pull-model
make health
```

n8n is at `http://localhost:5678` behind basic auth. Full instructions,
including the macOS Ollama GPU caveat, are in `docs/setup.md`.

Validate without starting anything:

```bash
make validate        # compose config + shell syntax
make secrets-scan    # nothing credential-shaped is tracked
```

## Environment variables

All configuration is in `.env`, created from `.env.example`. Nothing is
hardcoded, and `docker-compose.yml` uses `${VAR:?message}` for required values
so a missing secret fails at start with a clear message.

| Group | Required for |
|---|---|
| `POSTGRES_*`, `REDIS_*`, `N8N_*` | Starting the stack. Generated by `make init`. |
| `LLM_API_KEY`, `LLM_MODEL` | Every agent. |
| `OLLAMA_*` | The classifier. |
| `CADDY_DOMAIN`, `WEBHOOK_URL` | Public access. Placeholders until a domain exists. |
| `TELEGRAM_*` | Phase 3 |
| `APOLLO_*` | Phase 4 |
| `EMAIL_*`, `SMTP_*`, `IMAP_*` | Phase 7 and 8 |
| `OUTREACH_*` | Safety rails. Defaults are deliberately restrictive. |

`N8N_ENCRYPTION_KEY` encrypts every credential stored in n8n. Back it up
somewhere other than this machine, and not next to the database dumps.

## Docker Compose

Five services with pinned versions, healthchecks, `restart: unless-stopped`,
named volumes and two networks (`backend` internal, `edge` for Caddy and n8n).

PostgreSQL, Redis, Ollama and n8n bind to `127.0.0.1`. Only Caddy publishes
externally, and only once a real domain is configured.

```bash
make up / down / restart / logs / ps
```

`make down` keeps all data. `make clean` deletes it and refuses to run without
`CONFIRM=yes`.

## Database

Eight tables plus five views. UUID primary keys, `timestamptz` throughout,
CHECK constraints instead of enums, and generated columns where a value must
never disagree with its parts.

| Table | Holds |
|---|---|
| `companies` | The root entity. Unique on `domain`. |
| `people` | Contacts and decision makers. |
| `signals` | Sourced evidence. Deduplicated per company and type. |
| `leads` | A (company, person) pair worth pursuing. |
| `outreach` | One row per outbound message, with its approval state. |
| `conversations` + `messages` | Reply threads, turn by turn. |
| `agent_runs` | Every LLM invocation, its input, output and duration. |
| `suppression_list` | Hard opt-out. Email or domain. |

The database enforces what matters rather than trusting the workflows:

- A trigger on `outreach` **rejects any message to a suppressed address**, so a
  workflow bug produces a failed transaction instead of an unwanted email.
- `total_score` and `score_band` are generated columns, so a score and its band
  cannot disagree.
- Unique indexes prevent duplicate signals, duplicate follow-ups and duplicate
  conversation threads on a retry.

Details in `postgres/README.md`.

## Agents

Five agents. Each one is a prompt, a JSON Schema and a place in the pipeline -
no agent runtime, no tool access. n8n calls the model, validates the response
against the schema, and writes rows.

| Agent | Model | Job |
|---|---|---|
| research | external | Investigate a company. Separates facts, inferences and unknowns. Never invents. |
| scoring | external | Apply the 100-point rubric. Absent evidence scores zero. |
| outreach | external | 120 words, one sourced problem, one offer, one question. May decline to write. |
| classifier | local | Eight categories. Opt-out outranks everything. |
| conversation | external | Answer technical and price questions inside hard limits. Escalates anything unusual. |

The limits that matter are enforced twice: stated in the prompt, then checked in
the workflow after the model returns. A model that has been talked into
something cannot act on it.

## n8n workflows

Thirteen workflows, each with one responsibility. WF-01 discovery, WF-02
research, WF-03 enrichment, WF-04 scoring, WF-05 drafting, WF-06 dispatch,
WF-07 follow-ups, WF-08 classification, WF-09 conversation, WF-10 opportunity
and Telegram, WF-99 errors, WF-100 daily report, WF-101 agent health.

Inputs, outputs, guards and failure handling for each are in
`docs/workflows.md`, along with the order they should actually be built in -
which is not numerical.

**WF-06 is the only workflow that sends anything,** and in Phase 1-7 it only
processes rows a human approved:

```
discover -> research -> score -> draft -> [ HUMAN APPROVAL ] -> send
```

## Security

- `.env` is gitignored and chmod 600; `make secrets-scan` fails on anything
  credential-shaped in a tracked file
- PostgreSQL, Redis and Ollama are never exposed beyond loopback. Ollama has no
  authentication at all.
- n8n is never public without TLS and authentication
- Cloudflare Tunnel for a home connection behind CGNAT
- Backups are GPG-encrypted; the n8n encryption key is stored separately
- The suppression list is enforced in discovery, in the dispatcher, and by a
  database trigger
- Outreach volume is rate limited, and `OUTREACH_PAUSED` is a single boolean
  stop button

Full detail, including the GDPR obligations and the prompt-injection posture,
in `docs/security.md`.

## Roadmap

14 phases, in `docs/roadmap.md`. The ordering principle is **quality before
volume, and human approval before automation**.

Phase 1 repository (this) - 2 deployment - 3 Telegram - 4 discovery -
5 research - 6 scoring - 7 human-approved outreach - 8 classification -
9 conversation - 10 opportunity detection - 11 calendar - 12 sales memory -
13 Opportunity Radar - 14 controlled autonomous outreach.

Phase 14 is not a goal to rush toward. The system is more valuable producing
twenty good drafts a day that a person approves in five minutes than sending two
hundred unattended.

## License

Private. Not published.
