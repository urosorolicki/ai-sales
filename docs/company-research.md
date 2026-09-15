# WF-02 Company Research

Turns a company with `status = 'new'` into an evidence file: an enriched
`companies` row, one `signals` row per sourced pain signal, and an `agent_runs`
row recording what the model was asked and what it answered.

Artifact: `n8n/workflows/ai-sales-company-research.json`
Prompt: `prompts/research.md`
Schema: `agents/research/schema.json`

```
Every 30 Minutes
  -> Read Research Prompt -> Prompt To Text        (prompts/research.md from disk)
  -> Claim Companies                               (FOR UPDATE SKIP LOCKED)
  -> Candidate URLs -> Fetch robots.txt -> Allowed URLs
  -> Split URLs -> Fetch Page -> Group Material    (fan out per page, fan back in per company)
  -> Open Triage Run -> Triage -> Validate Triage -> Close Triage Run   (local, free)
  -> Worth Researching?
        +-- false -> Park Company -> Skipped                            (no paid call)
        +-- true  -> Open Agent Run
                     -> Build Research Request -> Research Agent        (Anthropic, paid)
                     -> Validate Research -> Research Valid?
                          +-- true  -> Store Research -> Close Run Success -> Researched
                          +-- false -> Close Run Error
```

## Two models, on purpose

The expensive model is only called for companies that survive a free local
filter.

**Triage** runs on Ollama (`llama3.1:8b`) and answers exactly one question: is
there anything in this material worth paying a stronger model to look at? It
does not analyse the company, list its stack or judge it as a customer. A small
yes/no is what an 8B model is reliably good at, and it is the role
`agents/README.md` already assigns to the local model - which is why the triage
run is recorded with `agent_name = 'classifier'`.

**The filter is deliberately biased towards yes.** A false negative discards a
company permanently; a false positive costs a fraction of a cent. The prompt says
so in as many words, and the validator **fails open**: if Ollama is down, slow,
or returns something unusable, the company goes to the paid model anyway. A
broken filter must cost money, never silently lose leads.

Two things are checked before the model's opinion counts:

- `pages_fetched == 0` skips regardless. Nothing was fetched, so there is nothing
  for any model to research. That is mechanical, not a judgement.
- The `### SOURCE: <url>` headers are stripped from the triage input. Those URLs
  contain the candidate paths - `/careers`, `/blog`, `/engineering` - which are
  exactly the keywords triage looks for. Left in, the filter answers "yes, there
  is an engineering section" for *every* site, because the URL said so. This was
  a real bug, caught by running the workflow against a site with no engineering
  content and getting `true` back.

A skipped company is parked at `status = 'ignored'` with the reason on its
`classifier` run in `agent_runs`. Setting it back to `new` re-queues it.

### Measured on this machine

| | Time | Cost |
|---|---|---|
| Triage, clearly relevant material | 26s | free |
| Triage, marketing site | 7s | free |
| Triage, ambiguous | 5s | free |
| Full research | seconds | ~2-3c |

Those numbers were measured with Ollama in a container, on the CPU. It now runs
natively on the host with Metal, which is several times faster - see
`docs/ollama.md`.

## The prompt is read from disk, not embedded

`docker-compose.yml` mounts `./prompts` read-only at `/prompts`. The workflow
reads `prompts/research.md` on every run and extracts the fenced block under
`## System prompt`. That file is the single source of truth; there is no copy
inside the workflow JSON to drift out of sync.

If the heading or the fence is removed, the node throws rather than sending the
whole markdown file as a prompt.

## Fetching

Six conventional paths per company: `/`, `/about`, `/careers`, `/jobs`,
`/blog`, `/engineering`. This is a research pass, not a crawl.

**robots.txt is respected.** It is fetched first, parsed for our user agent
(`AiSalesMachineBot`, falling back to the `*` group), and longest-match wins
between `Allow` and `Disallow` as RFC 9309 specifies. A missing or unreadable
robots.txt means allow - that is the documented default. Disallowed URLs are not
fetched and are passed to the model as "disallowed by robots.txt", so their
absence is visible rather than silently missing.

Every request has an explicit timeout (10s for robots, 15s per page) per
`n8n/README.md`. Failures are recorded, not raised: a 404, a timeout or a page
with no usable text becomes an entry in `fetch_failures` that the model is told
about.

HTML is reduced to text with script, style and comment blocks removed, capped at
6000 characters per page and 24000 in total. An unbounded page is an unbounded
bill.

## Model configuration

| | |
|---|---|
| Model | `LLM_MODEL`, currently `claude-sonnet-5` |
| Max tokens | `LLM_MAX_TOKENS`, currently 4096 |
| Temperature | **not sent** - see below |
| Caching | `cache_control: ephemeral` on the system prompt |

**`LLM_TEMPERATURE` does not apply to this model.** `claude-sonnet-5` rejects
`temperature`, `top_p` and `top_k` with an HTTP 400. Sending the 0.2 from `.env`
would fail every request. Assistant prefill is rejected the same way, so JSON is
obtained by instruction and enforced by validation, not by prefilling `{`.

The system prompt is identical for every company in a batch and between runs, so
it carries a cache breakpoint. Check `usage.cache_read_input_tokens` on the
stored `agent_runs.output` to confirm it is being hit.

## Validation

The response is checked against `agents/research/schema.json`: all twelve
required keys, their types, `confidence` in 0-1, `recommended_service` in its
enum, and every `pain_signals.signal_type` against the same enum the `signals`
table enforces - so a bad value fails here rather than as a failed insert later.

`stop_reason` is checked **before** the content is read. A `refusal` and a
`max_tokens` truncation both produce output that looks parseable but is not the
answer.

Nothing is repaired. A markdown fence around otherwise-valid JSON fails the run.

## What gets written

On success, one statement updates `companies` and inserts `signals`, so a
company is never left `researched` with no evidence because a second query
failed:

| Column | From |
|---|---|
| `companies.description` | `company_summary` |
| `companies.tech_stack` | `technology` |
| `companies.hiring_signals` | `hiring_signals` |
| `companies.pain_signals` | `pain_signals` |
| `companies.status` | `researched` |
| `signals` | one row per `pain_signals` entry |

`signals` has a unique index on `(company_id, signal_type, md5(signal))` and the
insert is `ON CONFLICT DO NOTHING`, so re-running is idempotent at the database
level rather than by workflow discipline.

`agent_runs` records `prompt_tokens` and `output_tokens` from the API response.

## Failure and retries

A failed run is closed as `error` and the company goes back to `new` for the
next scheduled pass. After three failures it is parked at `ignored` instead of
cycling forever.

The retry count is **not** a column. It is `count(*)` over `agent_runs` rows for
that company with `agent_name = 'research'` and `status = 'error'` - the audit
trail already knows, so there is no migration and no counter to keep in sync.

The Research Agent node retries once on a transport failure (429, 5xx), five
seconds apart. A schema failure is not retried inside the run; the company
returns to the queue and the next scheduled pass is the retry.

WF-99 is set as the error workflow, and `$execution.id` is recorded in
`agent_runs.input`, so a run left at `running` by a crashed execution is closed.

## Required credentials

| Credential | Type | Status |
|---|---|---|
| Postgres account | `postgres` | exists |
| **Anthropic** | `anthropicApi` | **must be created** |

Triage needs no credential: Ollama has no authentication, and its base URL is
configuration rather than a secret. Until the Anthropic credential exists, every
company that passes triage fails with `Credentials not found`, is recorded as an
error run and returns to the queue - so nothing is lost, and the free half of the
pipeline keeps working.

Create it under Credentials > New > Anthropic, paste the API key, then open the
**Research Agent** node and select it. `docs/security.md` requires credentials to
live in n8n's credential store - not in node parameters and not in environment
variables read by expressions - so the workflow does not read `LLM_API_KEY` from
`.env`.

n8n's built-in "test" button for this credential calls a retired Claude model. A
failure there does not necessarily mean the key is wrong; the workflow itself is
the real test.

## Running it

Schedule, every 30 minutes, when the workflow is activated. To run it by hand,
open it and click **Test workflow** - the CLI cannot start a schedule-triggered
workflow.

Give it something to do first:

```sql
INSERT INTO companies (name, domain, website, industry, status, source)
VALUES ('Some Company', 'somecompany.com', 'https://somecompany.com', 'SaaS', 'new', 'manual');
```

It claims five companies per run. That number is in the `Claim Companies` node;
there is no environment variable for it yet.

## Verifying

```sql
SELECT c.name, c.status, c.score_band,
       jsonb_array_length(c.tech_stack) AS tech,
       (SELECT count(*) FROM signals s WHERE s.company_id = c.id) AS signals,
       r.status AS last_run, r.prompt_tokens, r.output_tokens, r.duration_ms
FROM companies c
LEFT JOIN LATERAL (
    SELECT * FROM agent_runs
    WHERE company_id = c.id AND agent_name = 'research'
    ORDER BY started_at DESC LIMIT 1
) r ON true
ORDER BY c.created_at DESC;
```

## Not implemented

**Playwright.** `docs/architecture.md` lists it as the fallback for pages that
need JavaScript, but it is not in `docker-compose.yml` and no service was added
for it. A page that renders nothing useful is recorded in `fetch_failures` and
flagged as `rendering_unavailable`, so the gap is visible in the data rather
than silently treated as "this company has no careers page".

**Per-domain fetch rate limiting across runs.** Within a run each company is
fetched at most six times. There is no cross-run counter; that belongs in Redis,
and there is no Redis credential in n8n yet.

**WF-04 is not called on completion.** The spec has WF-02 trigger scoring when it
finishes. WF-04 does not exist yet.
