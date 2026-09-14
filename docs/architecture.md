# Architecture

## What this is

A single-host pipeline that turns public evidence about companies into
human-approved outreach, and then into managed conversations. It is a data
pipeline with language models in some of the steps, not an autonomous agent
system.

## Shape

```
                    +-----------------------------+
                    |  Caddy  (TLS, reverse proxy)|
                    +--------------+--------------+
                                   | :5678
                    +--------------v--------------+
                    |            n8n              |
                    |  orchestration, scheduling, |
                    |  retries, credentials       |
                    +--+--------+--------+--------+
                       |        |        |
        +--------------v-+  +---v----+  +v-----------------+
        |   PostgreSQL   |  | Redis  |  |  Ollama          |
        | system of      |  | queue, |  |  local model,    |
        | record         |  | cache, |  |  bulk + cheap    |
        |                |  | rate   |  |                  |
        +----------------+  | limits |  +------------------+
                            +--------+
                       |
        +--------------v----------------------------------+
        |  External services (outbound only)              |
        |  LLM API  |  Apollo  |  SMTP/IMAP  |  Telegram  |
        +-------------------------------------------------+
```

## Components and why each one is there

| Component | Role | Why this one |
|---|---|---|
| **PostgreSQL** | System of record. Every company, person, lead, signal, message and agent run. | Constraints, transactions and generated columns let the database enforce rules the workflows would otherwise have to remember. The suppression trigger is the clearest example. |
| **n8n** | Orchestrator. Schedules, retries, holds credentials, sequences the steps. | The hard part of this system is scheduling and state, not intelligence. n8n has both, plus a visual audit trail of what ran. It also uses PostgreSQL, so there is one thing to back up. |
| **Redis** | n8n queue mode, rate-limit counters, short-lived caches. | Required by n8n for queue mode; convenient for per-domain send counters that must not be lost on restart but do not belong in PostgreSQL. |
| **Ollama** | Local model for high-volume, low-stakes work: reply classification, extraction, deduplication. | Classification runs on every inbound message. Paying per token for that is a running cost with no quality benefit. |
| **External LLM** | Research, scoring, outreach drafting, conversation. | The steps where being wrong is expensive. This is where quality is worth money. |
| **Caddy** | TLS termination and reverse proxy. | Automatic certificates, a five-line config, no cron for renewals. |
| **Playwright** | Rendering pages that need JavaScript (some careers pages and job boards). | Used only where a plain fetch fails. It is not part of the default path. |
| **Telegram** | The human interface: approvals, alerts, status. | Already on the phone, trivial bot API, good enough for approve/reject. No UI to build. |

## Data flow

```
  discovery -> research -> enrichment -> scoring -> draft
                                                     |
                                            [ human approval ]
                                                     |
                                                   send
                                                     |
                                         reply -> classify -+
                                                            |
                              +-----------------------------+
                              |              |              |
                        conversation     escalate       suppress
                           agent        to human      (unsubscribe)
```

Every arrow is a separate n8n workflow with its own schedule, its own error
handling and its own row in `agent_runs`. Nothing is a single large workflow.

## Design decisions

**PostgreSQL is the queue.** Work is selected by status and timestamp with
`FOR UPDATE SKIP LOCKED`, not pushed through a message broker. At this volume -
tens to low hundreds of companies a day - a broker is a component to operate
for no benefit, and the database already has to be consistent.

**One process per responsibility, not one service per responsibility.** There
are no custom microservices. The agents are prompts and schemas; n8n is the
runtime. Adding a service means adding a deployment, a healthcheck, a log
stream and a failure mode, and none of the agents need one.

**The database enforces the rules that matter.** Suppression is a trigger.
Scoring bands are generated columns. Duplicate follow-ups are a unique index.
A workflow bug should produce a failed insert, not an unwanted email.

**Human approval is a state, not a setting.** `pending_approval` is a real
status with a real queue and a real index behind it. Turning on automatic
sending later means changing which transition is automatic, not rebuilding the
pipeline.

**No Kubernetes.** One host, five containers, restart policies, a health check
and a backup. Kubernetes here would be more moving parts than workload.

## Scaling limits

This design is comfortable to roughly 500 companies researched per day and a
few thousand conversations in flight, on one Mac Mini. The first things to
break, in order:

1. External LLM cost, long before anything technical.
2. Email reputation, which is a policy limit, not a capacity limit.
3. Playwright memory, if rendering becomes the default rather than the fallback.
4. PostgreSQL, somewhere far past the point where any of the above matter.

None of these are solved by adding services now.
