# Roadmap

Each phase is usable on its own and leaves the system in a working state. No
phase begins before the one before it produces something worth keeping.

The ordering principle: **quality before volume, and human approval before
automation.** Sending more of a bad email faster is the only outcome the
opposite ordering produces.

---

## Phase 1 - Repository foundation

**Status: complete.** Compose stack, schema, migrations, prompts, agent
contracts, workflow specification, Makefile, health check, backup, security
documentation. Nothing is deployed.

**Done when:** `make validate` passes and the repository can be cloned onto the
Mac Mini.

## Phase 2 - Mac Mini deployment

Bring the stack up for real. `make init`, `make up`, `make migrate`,
`make pull-model`, `make health`. Cron for backups and health. Energy settings
so the machine actually stays awake.

**Done when:** the stack survives a reboot unattended and a restore from backup
has been tested once.

## Phase 3 - Telegram control plane

Bot, chat id authorisation, WF-10, WF-99, WF-100, WF-101. Nothing to report on
yet, which is the point: build the feedback channel before the thing that needs
reporting.

**Done when:** a daily report arrives, and a deliberately broken workflow
produces exactly one alert.

## Phase 4 - Lead discovery

WF-01. Apollo or another provider, deduplication on domain, suppression checked
at entry, a hard daily credit limit.

**Done when:** companies arrive daily at `status = 'new'` and the credit limit
has been observed to actually stop it.

## Phase 5 - Company research

WF-02 and the research agent. Fetching, Playwright as a fallback only, signal
extraction with sources.

**Done when:** twenty companies have been researched and a human reading the
output agrees with the facts and finds no invented ones. This is the phase to
be slowest about.

## Phase 6 - Lead scoring

WF-04, WF-03. The rubric, the overrides, the enrichment that only happens above
the threshold.

**Done when:** the band distribution separates, and a human agrees with the
ranking of the top twenty.

## Phase 7 - Human-approved outreach

WF-05, WF-06, WF-07, with `OUTREACH_AUTOSEND_ENABLED=false` and every send
approved individually through Telegram.

**Done when:** fifty drafts have been reviewed, the approval rate is above half,
and the sends that went out produced no complaints.

## Phase 8 - Reply classification

WF-08. Local classification, escalation on low confidence, and above all
suppression that works on the first opt-out.

**Done when:** every opt-out in a test set is caught, and no auto-reply has been
misread as interest.

## Phase 9 - Conversation automation

WF-09, still queuing every generated reply for human approval. The hard limits
enforced in the workflow, not only the prompt.

**Done when:** twenty agent replies have been reviewed and the human would have
sent them unchanged.

## Phase 10 - Opportunity detection

Opportunity state, escalation, notification with enough context to answer from
the phone.

**Done when:** a positive reply reaches the phone within a minute with the
thread and the research attached.

## Phase 11 - Calendar integration

Availability lookup and booking, only after a human has accepted the
opportunity. The agent proposes; it never commits to a date on its own.

**Done when:** a meeting has been booked end to end without a double booking.

## Phase 12 - Sales memory / pgvector

`CREATE EXTENSION vector`, embeddings over past conversations, objections and
what worked. Retrieval feeding the outreach and conversation agents.

Deliberately late: there is nothing worth remembering until several dozen real
conversations exist, and building this first produces a vector store full of
nothing.

**Done when:** a draft demonstrably reuses a phrasing that previously worked, and
a human agrees it is better.

## Phase 13 - Opportunity Radar

See `docs/opportunity-radar.md`. The shift from buying lists to detecting
evidence. This is the part that makes the system worth running.

**Done when:** a company discovered by the radar, not by a provider, becomes a
paying client.

## Phase 14 - Controlled autonomous outreach

Only now does `OUTREACH_AUTOSEND_ENABLED=true` become a question worth asking,
and only for a narrow slice: the highest-scoring band, the most-reviewed
template, a low daily cap, and a human reading every send after the fact.

**Preconditions, all of them:**

- At least 200 drafts reviewed with a sustained approval rate above 80%
- Zero missed opt-outs over at least 100 replies
- WF-99, WF-100 and WF-101 have been running reliably for a month
- A human still reads every send, after the fact, daily

If any of those is not true, the answer is no. The system is more valuable
producing twenty good drafts a day that a person approves in five minutes than
sending two hundred unattended.
