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
  -> ATS Candidates -> Fetch ATS Board -> Merge ATS Material   (external job boards)
  -> Open Triage Run -> Triage -> Validate Triage -> Close Triage Run   (local, free)
  -> Worth Researching?
        +-- false -> Park Company -> Skipped                            (no paid call)
        +-- true  -> Open Agent Run
                     -> Build Research Request -> Research Agent        (local, free)
                     -> Validate Research -> Research Valid?
                          +-- true  -> Store Research -> Close Run Success -> Researched
                          +-- false -> Close Run Error
```

## Per-domain rate limiting

`docs/workflows.md` lists a per-domain fetch rate limit as a guard on WF-02.
There are two of them, because they solve different problems.

**Inside one run**, the Fetch Page node sends one request at a time with
`RESEARCH_FETCH_BATCH_INTERVAL_MS` (1000) between them. Split URLs emits one
company's pages consecutively, so a global interval is in practice a per-domain
interval.

**Between runs**, nothing in n8n remembers anything, so the limit lives in
`domain_fetch_log` (`postgres/migrations/0012_fetch_throttle.sql`). A pass every
30 minutes, a retry loop, and a company that keeps failing back to `new` can
otherwise hit the same host dozens of times an hour with nothing noticing.

`claim_domain_fetch()` tests and stamps in one statement, so two concurrent runs
cannot both decide a domain is free. It is applied **at claim time**, not at
fetch time, which is why `Claim Companies` reads a candidate pool
(`RESEARCH_CANDIDATE_POOL`, 25) wider than the batch it wants
(`RESEARCH_BATCH_SIZE`, 5): a company whose domain is still cooling down is never
claimed, so it stays at `new` and a company behind it in the queue takes the
slot. Filtering after claiming would strand rows at `researching`.

Being refused is not an error and nothing is logged for it. The company waits
for the next pass, which is what a rate limit is supposed to do.

Redis would have been the obvious place for this and was not used: n8n has a
Postgres credential and no Redis one, and "when did we last touch this domain"
is worth keeping across a restart.

## One model, five companies, one queue

Ollama serves one request at a time: `llama-server` is started with `-np 1`, so
`RESEARCH_BATCH_SIZE` companies do not research in parallel no matter how many
HTTP requests n8n opens. They queue, and the last one waits out all the others
before its own call begins.

`RESEARCH_MODEL_TIMEOUT_MS` is a wall-clock timeout on the HTTP request, so it
has to cover the **queue**, not the model. Measured on this machine with a batch
of five: 30 minutes wall clock, one success and four `timeout of 900000ms
exceeded`. A single company answers in about three minutes, so nothing was slow;
four requests simply spent their fifteen minutes waiting for a turn.

The fix is the timeout, not the batch size - the batch is what keeps the GPU
busy. Budget roughly `RESEARCH_BATCH_SIZE x per-company time x 1.5`, which is
why this machine runs `RESEARCH_MODEL_TIMEOUT_MS=2700000`.

This gets worse as the material grows, and the ATS stage grows it: a company
with a job board sends up to `RESEARCH_MATERIAL_MAX_CHARS` instead of the 24000
it sent before, and a longer prompt is a longer call.

## Two models, on purpose

The expensive model is only called for companies that survive a free local
filter.

Both models are local and both are free. The split is about speed, not money:
triage is small and runs on every company, research is large and runs only on
the ones that survive it.

**Triage** runs on `llama3.1:8b` (`OLLAMA_MODEL`) and answers exactly one
question: is there anything in this material worth handing to the bigger model? It
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

**Research** runs on `qwen9-64k` (`OLLAMA_RESEARCH_MODEL`), a 9B model with a
64k context window. The context size is not optional: the research schema plus a
page of fetched material does not fit in Ollama's default 4096 tokens, and the
object comes back cut off mid-key. That failure is caught - `finish_reason` of
`length` is a validation error naming the fix - but the run is wasted.

### The endpoint matters

Research posts to Ollama's **OpenAI-compatible** endpoint,
`/v1/chat/completions`, not to `/api/chat`.

On the installed version, `/api/chat` silently ignores `format`. A schema
requiring two keys produced neither of them, an enum of three colours produced a
fourth, and the full research schema came back with the array fields and none of
the scalar ones - across two different models. `response_format` with
`strict: true` on `/v1/chat/completions` is enforced: exactly the required keys,
no extras.

Validation still runs regardless. Enforcement fixes the *shape*; it does nothing
about a `confidence` of 0.95 on four lines of evidence.

### Measured on this machine

One company, six pages, end to end through n8n:

| | Time |
|---|---|
| Triage (`llama3.1:8b`) | 9s |
| Research (`qwen9-64k`) | 171s, 5068 in / 1002 out tokens |
| **Whole workflow** | **under 3 minutes, no cost** |

Both on the GPU. See `docs/ollama.md` for why Ollama is not in a container.

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

### External ATS job boards

Those six paths miss the hiring signal for most companies of this profile. Of 38
European companies probed, a board was reachable for 19 of them, and the adverts
were on Greenhouse, Ashby, Lever, Workable, Recruitee, Teamtailor or Personio
rather than on the company's own site. All seven answer with public JSON and no
credential, so **this does not need Playwright**, which was the assumption in
`docs/architecture.md`.

The slug is found two ways, and they catch different companies:

- **From a link** on the company's own careers page. This is harvested in
  `Group Material` from the *raw* HTML, because `htmlToText` discards the href
  and the href is where the slug is. A published link is not a guess, so when
  there is one no other board is probed.
- **Guessed from the domain**, which covered 17 of the 38. `smartly.io` shows
  why both are needed: its slug is `smartlyio`, so the guess misses and the link
  finds it.

`Merge ATS Material` decides what reaches the model, and the split matters:

| Part | Budget | Answers |
|---|---|---|
| Every open role, title and location | `3000` chars | how much, and for what, they are hiring |
| Full text of the infrastructure roles, best first | the rest of `RESEARCH_ATS_MAX_CHARS` | whether they run their own infrastructure |

Titles alone are not enough and that is the whole point. A board returning only
titles says "Backend Engineer"; the description is where Kubernetes and
Terraform appear. Measured on Monzo's board: zero infrastructure terms in the
titles, thirty in the descriptions.

Descriptions are **not** truncated from the front. An advert opens with several
paragraphs about the company and names its tools much later, so the first 1800
characters are the marketing. Paragraphs are ranked by infrastructure content
and kept in their original order, which cut GoCardless from 12846 characters to
4031 while keeping Kubernetes, Terraform, ArgoCD and Prometheus.

Role relevance is weighted rather than counted. A flat count of keyword hits put
"Senior Credit Risk Manager, Credit Platform" above a backend role that actually
names Kubernetes, because it said "SLA" twice and had "Platform" in its title.
Terms only written by a team running its own infrastructure score highest, and
the title bonus requires the role itself, not a word inside another one.

The ATS block is placed **first** in the material: if anything has to be cut to
fit `RESEARCH_MATERIAL_MAX_CHARS`, it must be the home page copy, never the
adverts.

A company whose boards all answer 404 is not a failure. That is the normal reply
to a guessed slug, it is not logged, and the company continues to triage with
whatever its own site gave.

Four providers were researched and deliberately left out: SmartRecruiters,
Workday, Rippling and Join.com all list titles only and need a second request
per advert. That N+1 traffic needs its own rate-limiting decision first.

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

## What the local model is and is not good at

From a real run against a site with an open SRE role, a Terraform requirement, a
45-minute CI pipeline and two incidents caused by a manual release step:

**Good.** Seven pain signals with varied, correct `signal_type` values;
eight technologies, all of them actually named in the material; the right
`recommended_service`; correct source URLs; sensible `unknown` entries.

**Weak.** `company_summary` comes back as the company's name rather than the two
sentences the prompt asks for - every qwen model tested did this. `why_now` came
back as `active_hiring_for_infrastructure_fixes` rather than a sentence. Every
signal was given `confidence: 1.00`. `confidence` for the whole file was 0.95 on
thin evidence, where the prompt explicitly asks for a low number.

So the evidence extraction is usable and the *judgement* is not calibrated. That
matters for WF-04, which scores on these fields.

### Moving research to an external model

`prompts/research.md` and `agents/research/schema.json` do not change. Three
things do:

1. **Research Agent** node: URL to `https://api.anthropic.com/v1/messages`,
   authentication to the `anthropicApi` credential, and an
   `anthropic-version: 2023-06-01` header.
2. **Build Research Request**: Anthropic's shape - `system` as a list of blocks
   with `cache_control`, `max_tokens` top level, no `response_format`. Send **no
   `temperature`**: `claude-sonnet-5` rejects sampling parameters with a 400, so
   `LLM_TEMPERATURE` does not apply to it. Assistant prefill is rejected the same
   way, so JSON comes from the instruction and from validation.
3. **Validate Research** and **Close Run Success**: `content[].text` and
   `stop_reason` instead of `choices[].message.content` and `finish_reason`;
   `usage.input_tokens` / `output_tokens` instead of `prompt_tokens` /
   `completion_tokens`.

That version is in the history at commit `7360d9b` if it is wanted back.

## Validation

`agents/research/schema.json` is read from disk at runtime (`./agents` is mounted
read-only at `/agents`) and drives both halves: it is sent to the model as the
`response_format` schema, and the validator reads the required keys, the types,
the `confidence` bounds and both enums straight out of it. There is one
definition of the contract, not a copy in the workflow that can drift.

`finish_reason` is checked **before** the content is read: a truncated object
looks parseable right up to the point where it is not.

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

That is the only one. Neither model needs a credential: Ollama has no
authentication, and its base URL is configuration rather than a secret.

Both models must be pulled on the host - `llama3.1:8b` and whatever
`OLLAMA_RESEARCH_MODEL` names. `make health` reports how many are present.

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
there is no environment variable for it yet. At roughly three minutes each, a
full batch takes about fifteen minutes - comfortably inside the thirty minute
schedule, but not by much.

## Verifying

How much the ATS stage is actually contributing, which is the number to watch
after any change to the discovery or the weighting:

```sql
SELECT c.name,
       r.input -> 'ats' ->> 'provider'      AS board,
       r.input -> 'ats' ->> 'via'           AS found_by,
       r.input -> 'ats' ->> 'total_jobs'    AS roles,
       r.input -> 'ats' ->> 'relevant_jobs' AS infra_roles,
       r.input -> 'ats' ->> 'top_title'     AS best_role,
       r.input ->> 'ats_attempted'          AS boards_tried,
       r.input ->> 'material_chars'         AS chars,
       c.total_score, c.score_band
FROM agent_runs r
JOIN companies c ON c.id = r.company_id
WHERE r.agent_name = 'research'
ORDER BY r.started_at DESC;
```

A `board` of null with `boards_tried` of 5 or more means every guess answered
404 and the company published no link: that company is researched on its own
pages only, which is the pre-ATS behaviour and the expected outcome for roughly
half of them. A `found_by` of `guess` that keeps returning boards with zero
`infra_roles` is worth checking by hand - it may be the wrong company's board.

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
for it. It is also less needed than it looked: the case it was wanted for was
the JavaScript-rendered careers page, and the ATS job boards answer that with
public JSON instead. A page that renders nothing useful is recorded in `fetch_failures` and
flagged as `rendering_unavailable`, so the gap is visible in the data rather
than silently treated as "this company has no careers page".

**Per-domain fetch rate limiting across runs.** Within a run each company is
fetched at most six times. There is no cross-run counter; that belongs in Redis,
and there is no Redis credential in n8n yet.

**WF-04 is not called on completion.** The spec has WF-02 trigger scoring when it
finishes. WF-04 does not exist yet.
