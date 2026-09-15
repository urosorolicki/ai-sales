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
the survivors reach the larger research model. Playwright and cross-run
per-domain rate limiting are not implemented.

| | |
|---|---|
| Trigger | Schedule, every 30 minutes |
| Input | Up to N companies with `status = 'new'`, claimed and set to `researching` |
| Steps | Fetch careers page, engineering blog, about page, public repos; Playwright only if a plain fetch returns nothing usable; call the research agent |
| Output | `companies` enriched, `status = 'researched'`; one `signals` row per sourced signal |
| Guards | Per-domain fetch rate limit; respect robots.txt; hard timeout per company |
| Failure | Fetch failure is recorded in `unknown`, not retried aggressively. Schema failure retries once, then `agent_runs.status = 'error'` and the company returns to `new` with a retry counter. |

## WF-03 Contact Enrichment

| | |
|---|---|
| Trigger | Schedule, hourly |
| Input | Companies with `score_band` in OUTREACH, HIGH_PRIORITY or HOT and no contactable person |
| Steps | Provider lookup for decision makers; email verification |
| Output | `people` rows; `companies.status` moves `enriching` then `ready` |
| Guards | Only enrich companies that already scored above the threshold. Enrichment costs money; never enrich before scoring. |
| Failure | No contact found is a normal outcome. The company stays scored and is not retried for 30 days. |

## WF-04 Lead Scoring

**Built** - see `docs/lead-scoring.md`. It polls for researched companies rather
than being called by WF-02, and the rubric's checkable rules are enforced in code
rather than trusted to the model. The nightly re-scoring sweep is not built.

| | |
|---|---|
| Trigger | Schedule, every 15 minutes (not called by WF-02 - see `docs/lead-scoring.md`) |
| Input | A researched company, its `signals`, its `people` |
| Output | `companies.fit_score`, `research_score`, `decision_maker_score`, `status = 'scored'`; `leads` rows for contactable decision makers |
| Guards | Never writes `total_score` or `score_band`, which are generated columns. Applies the hard overrides from `docs/scoring.md`. |
| Failure | A mismatch between the model total and the database total is logged through WF-99; the database value stands. |

## WF-05 Outreach Generation

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

## WF-10 Opportunity + Telegram

| | |
|---|---|
| Trigger | Called by WF-08 on POSITIVE, by WF-09 on escalation, by WF-04 when a company reaches HOT |
| Output | Telegram message to `TELEGRAM_CHAT_ID` with the company, the person, the thread and the reason |
| Guards | Only `TELEGRAM_CHAT_ID` may issue commands back, checked before any command does anything |
| Failure | Telegram unavailable retries with backoff, then WF-99. The opportunity stays in `v_open_opportunities` regardless, so nothing is lost if the notification is. |

## WF-99 Error Handler

Set as the error workflow on every other workflow. **Built** - see
`docs/error-handling.md`. The Telegram half is not wired up yet, and neither is
the deduplication that goes with it.

| | |
|---|---|
| Trigger | n8n error trigger |
| Output | `agent_runs` updated to `error` where a row exists; Telegram alert, deduplicated so one broken schedule does not send 96 messages a day |
| Guards | Never retries the failed workflow itself. Alert text must not contain credentials or full message bodies. |

## WF-100 Daily Report

| | |
|---|---|
| Trigger | Schedule, once a day |
| Input | `v_daily_stats`, `v_hot_companies`, `v_open_opportunities` |
| Output | One Telegram message: discovered, researched, scored, awaiting approval, sent, replies, open opportunities, failures |
| Notes | The awaiting-approval count is the number that matters. A growing queue means the human is the bottleneck, which is the intended state early on. |

## WF-101 Agent Health

| | |
|---|---|
| Trigger | Schedule, hourly |
| Input | `v_agent_health`, plus `agent_runs` stuck in `running` for over 15 minutes |
| Output | Telegram alert on: error rate above threshold, any agent with zero runs in 24h that should have run, stuck runs, Ollama unreachable, external LLM failures |
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
4. WF-10 and WF-100, so there is a feedback loop.
5. WF-01 and WF-03 only once the pipeline produces drafts worth having.
6. WF-06, last, and only after a human has approved and read a batch.
