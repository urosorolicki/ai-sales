# n8n workflows

n8n is the orchestrator. Each workflow has one responsibility, its own
schedule, its own error output and its own `agent_runs` rows. There is no
single large workflow and there should never be one: a failure in discovery
must not be able to stop a reply from being classified.

Workflows are exported as JSON into `n8n/workflows/` and imported on a new
machine. See `n8n/README.md` for the export and import procedure.

## Conventions

- **Input** is what triggers the workflow and what it selects from the database.
- **Output** is what it writes and what it hands on.
- Work is claimed with `SELECT ... FOR UPDATE SKIP LOCKED` so two runs cannot
  process the same row.
- Every LLM call writes an `agent_runs` row, `running` before and terminal
  after.
- Every workflow sets WF-99 as its error workflow.
- Every workflow is idempotent: re-running it must not duplicate a row or
  resend a message.

---

## WF-00 Pipeline Test

The smoke test, not part of the pipeline. Proves n8n -> Ollama -> PostgreSQL
before anything real is built on top of it. Full detail in
`docs/pipeline-test.md`.

| | |
|---|---|
| Trigger | Manual |
| Input | One hardcoded fictional company |
| Output | One `agent_runs` row, on a fixed id so re-running updates rather than duplicates |
| Guards | Malformed model output fails the run; it is never repaired |
| Failure | Ollama error and validation error both close the run as `error` and fail the execution |

---

## WF-01 Lead Discovery

Finds candidate companies. Does not research them.

| | |
|---|---|
| Trigger | Schedule, daily |
| Input | Apollo search (Phase 4) or Opportunity Radar sources (Phase 13); `APOLLO_DAILY_LIMIT` |
| Output | `companies` rows with `status = 'new'`, deduplicated on `domain` |
| Guards | Skip domains on `suppression_list`; skip domains already present; stop at the daily credit limit |
| Failure | Provider error, retry once, then WF-99. Partial results are kept. |

## WF-02 Company Research

**Built** - see `docs/company-research.md`. Two local models, no API cost: a
cheap triage pass filters out companies with no engineering evidence, and only
the survivors reach the larger research model. Cross-run per-domain rate
limiting is enforced at claim time through `domain_fetch_log`. Playwright is not
implemented.

| | |
|---|---|
| Trigger | Schedule, every 30 minutes |
| Input | Up to N companies with `status = 'new'`, claimed and set to `researching` |
| Steps | Fetch careers page, engineering blog, about page, public repos; Playwright only if a plain fetch returns nothing usable; call the research agent |
| Output | `companies` enriched, `status = 'researched'`; one `signals` row per sourced signal |
| Guards | Per-domain fetch rate limit; respect robots.txt; hard timeout per company |
| Failure | Fetch failure is recorded in `unknown`, not retried aggressively. Schema failure retries once, then `agent_runs.status = 'error'` and the company returns to `new` with a retry counter. |

## WF-03 Contact Enrichment

**Built** - see `docs/contact-enrichment.md`. Not the provider lookup specified
below: there is no budget for one, so it reads the company's own website. An
address a company publishes is better provenance than a provider record anyway;
what it costs is coverage, and finding nobody is the common outcome.

| | |
|---|---|
| Trigger | Schedule, hourly |
| Input | Companies with `score_band` in OUTREACH, HIGH_PRIORITY or HOT and no contactable person |
| Steps | Fetch the contact, team, about and careers pages; a local model transcribes the people; every name and address is verified against the fetched text; an address pattern observed on that domain may be applied to a named person |
| Output | `people` rows with `source_url` and `discovery_method`; `companies.status` back to `researched` so WF-04 re-scores and creates the lead |
| Guards | Only enrich companies that already scored above the threshold. Only addresses on the company's own domain. Role addresses are never written as people. No blind guessing: a derived address requires a real one observed on the same domain. |
| Failure | No contact found is a normal outcome, recorded as a `skipped` run. The company goes back to `scored` and is not retried for 30 days. |

## WF-04 Lead Scoring

**Built** - see `docs/lead-scoring.md`. It polls for researched companies rather
than being called by WF-02, and the rubric's checkable rules are enforced in code
rather than trusted to the model. A nightly sweep puts stale scores and companies
that gained a contact back in the queue, and a company reaching `HOT` queues a
notification.

| | |
|---|---|
| Trigger | Schedule, every 15 minutes, plus a nightly re-scoring sweep at 03:20 (not called by WF-02 - see `docs/lead-scoring.md`) |
| Input | A researched company, its `signals`, its `people` |
| Output | `companies.fit_score`, `research_score`, `decision_maker_score`, `status = 'scored'`; `leads` rows for contactable decision makers |
| Guards | Never writes `total_score` or `score_band`, which are generated columns. Applies the hard overrides from `docs/scoring.md`. |
| Failure | A mismatch between the model total and the database total is logged through WF-99; the database value stands. |

## WF-05 Outreach Generation

**Built** - see `docs/outreach-generation.md`. The mechanical checks are enforced
in code and a failed draft is stored verbatim with its reason, never corrected. A
queued draft also queues the approval message from `docs/telegram.md`.

| | |
|---|---|
| Trigger | Schedule, hourly |
| Input | Leads with `status = 'new'` and `score >= OUTREACH_MIN_SCORE` |
| Steps | Outreach agent, then the mechanical checks: word count, banned phrases, `hook_source` present in the research sources, suppression |
| Output | `outreach` row moving `draft` to `pending_approval`; lead to `pending_approval` |
| Guards | `send: false` from the agent is respected and recorded. One draft per lead per `sequence_step`, enforced by a unique index. |
| Failure | A failed check leaves the draft at `draft` with the reason, so it can be inspected. It is never auto-corrected. |

## WF-06 Outreach Dispatcher

The only workflow that sends anything.

| | |
|---|---|
| Trigger | Schedule, every 15 minutes during working hours |
| Input | `outreach` rows with `status = 'approved'` |
| Guards, in this order | `OUTREACH_PAUSED` is false; recipient not suppressed; daily limit; per-domain limit; working-hours window |
| Output | Provider send; `status = 'sent'`, `sent_at`, `provider_message_id`; `conversations` row created; lead to `contacted` |
| Failure | A send error sets `failed` with the error text and does not retry automatically. A bounce sets `bounced` and adds the address to `suppression_list` with `hard_bounce`. |

Phase 1-7: no row reaches `approved` without a human. The dispatcher does not
know or care how approval happened, which is what makes turning on automation
later a one-line change rather than a redesign.

## WF-07 Follow-up Engine

| | |
|---|---|
| Trigger | Schedule, daily |
| Input | Leads at `contacted`, no inbound message, last send older than `OUTREACH_FOLLOWUP_DELAY_DAYS` |
| Output | A new `outreach` row at `sequence_step + 1`, through the same approval path as WF-05 |
| Guards | Stop at `OUTREACH_FOLLOWUP_MAX`. Stop immediately on any inbound message. Never follow up a suppressed address. Respect an out-of-office return date. |
| Failure | The final follow-up moves the lead to `nurture`, not back into the queue. |

## WF-08 Inbox Classifier

| | |
|---|---|
| Trigger | IMAP idle, or poll every 5 minutes |
| Input | New inbound messages |
| Steps | Match to a thread, filter auto-reply headers, classify on Ollama, re-classify on the external LLM if confidence is below 0.7 |
| Output | `messages` row with `classification`; `conversations.status`; `leads.status`; `suppression_list` on UNSUBSCRIBE |
| Guards | UNSUBSCRIBE and `requested_stop` are acted on before anything else. Confidence still below 0.7 after escalation goes to `awaiting_human`. |
| Failure | An unmatched message is stored and flagged for a human rather than discarded. |

## WF-09 Conversation Agent

| | |
|---|---|
| Trigger | Called by WF-08 for QUESTION and PRICE only |
| Input | Full thread, lead, research file |
| Output | Either an outbound `messages` row, or `conversations.status = 'escalated'` with a reason |
| Guards | Price checked against the offer table; discount ceiling; minimum project value; `commitments_made` non-empty routes to a human; contract and date keywords force escalation |
| Failure | Any check failing escalates. The message is blocked, never edited to comply. |

Phase 9 and earlier, replies generated here are queued for human approval too.
Only once quality is demonstrated does this workflow send directly.

## WF-10 Telegram Dispatch

**Built** - see `docs/notifications.md`. It came out inverted from the sketch
below: nothing calls it. Workflows write a row to `notifications` and WF-10
drains that outbox on a schedule, which is what makes "the opportunity stays in
`v_open_opportunities` regardless" true for every notification rather than just
for opportunities. The command half, and the WF-08/WF-09 triggers, are not built
because those workflows do not exist yet.

| | |
|---|---|
| Trigger | Schedule, every 5 minutes |
| Input | The `notifications` outbox: written by WF-04 on HOT, WF-05 on a queued draft, WF-99 on a failure, WF-100 and WF-101 |
| Output | Telegram message to `TELEGRAM_CHAT_ID`; `notifications.status` to `sent` or `failed` |
| Guards | Claims nothing unless `TELEGRAM_ENABLED=true` and `TELEGRAM_CHAT_ID` is set. Only `TELEGRAM_CHAT_ID` may issue commands back, checked before any command does anything. |
| Failure | Retries with a backoff up to `NOTIFY_MAX_ATTEMPTS`, then leaves the row at `failed` and WF-101 reports it. Nothing is deleted, so nothing is lost if the notification is. |

## WF-99 Error Handler

Set as the error workflow on every other workflow. **Built** - see
`docs/error-handling.md`. It queues a deduplicated alert into the notifications
outbox; WF-10 delivers it.

| | |
|---|---|
| Trigger | n8n error trigger |
| Output | `agent_runs` updated to `error` where a row exists; one deduplicated `notifications` row, so one broken schedule does not send 96 messages a day |
| Guards | Never retries the failed workflow itself. Alert text must not contain credentials or full message bodies. |

## WF-100 Daily Report

**Built** - see `docs/notifications.md`.

| | |
|---|---|
| Trigger | Schedule, daily at 08:00 |
| Input | `v_daily_stats`, `v_hot_companies`, `v_open_opportunities` |
| Output | One `notifications` row per day: awaiting approval first, then discovered, signals, leads, sent, replies, failures, the pipeline census, the top companies and the agent summary |
| Notes | The awaiting-approval count is the number that matters. A growing queue means the human is the bottleneck, which is the intended state early on. |

## WF-101 Agent Health

**Built** - see `docs/notifications.md`. "An agent that should have run" is not
observable on its own, so every idleness check is paired with evidence that
there was work: a queue with something in it, old enough that a run should
already have happened. An idle agent with an empty queue is healthy.

| | |
|---|---|
| Trigger | Schedule, hourly |
| Input | `v_agent_health`, `agent_runs` stuck in `running`, queue depth per stage, companies abandoned at `researching`, undeliverable notifications, and a live check on Ollama |
| Output | A `notifications` row per problem: error rate above threshold, an agent with work waiting and zero runs in 24h, stuck runs, Ollama unreachable or empty, orphaned companies, notifications that ran out of delivery attempts |
| Notes | An agent that silently stops running is the failure this exists to catch. |

## Dependency order

```
WF-01 -> WF-02 -> WF-04 -> WF-03 -> WF-05 -> [human] -> WF-06 -> WF-07
                                                  |
                              WF-08 <-------------+
                                |
                    +-----------+-----------+
                    |           |           |
                  WF-09      WF-10     suppression
```

WF-99, WF-100 and WF-101 run beside all of it and depend on nothing.

## Build order

Do not build these in numerical order. Build the ones that make the next one
cheap to get right:

0. WF-00 first, once, to prove the runtime works. Then leave it alone.
1. WF-99 next. Without it, every other failure is silent.
2. WF-02 and WF-04, driven by companies inserted by hand. This is where
   quality is decided, and it costs nothing to iterate on.
3. WF-05, still with hand-entered companies. Read the drafts. If they are not
   good enough to send yourself, no amount of automation downstream helps.
4. WF-10 and WF-100, so there is a feedback loop. **Done**, along with WF-101.
   Delivery needs a bot token; until there is one the loop is
   `SELECT * FROM v_pending_notifications`.
5. WF-01 only once the pipeline produces drafts worth having. WF-03 is
   **done**, reading company websites rather than a paid provider.
6. WF-06, last, and only after a human has approved and read a batch.
