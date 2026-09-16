# WF-03 Contact Enrichment

Finds the person to write to, from the company's own website, for nothing.

Artifact: `n8n/workflows/ai-sales-contact-enrichment.json`
Prompt: `prompts/enrichment.md` · Schema: `agents/enrichment/schema.json`
Migration: `postgres/migrations/0013_enrichment.sql`

```
Every Hour
  -> Read Enrichment Prompt / Read Enrichment Schema   (both from disk)
  -> Claim Companies                     (claim + open the run in one statement)
  -> Contact URLs -> Fetch robots.txt -> Allowed URLs
  -> Split URLs -> Fetch Page -> Group Material
  -> Build Enrichment Request -> Enrichment Agent      (local, ~30s)
  -> Validate And Verify -> Usable Response?
       +-- true  -> Anything Found?
       |              +-- true  -> Write People -> Close Run Success -> Enriched
       |              +-- false -> Release Company -> Released        (run: skipped)
       +-- false -> Release Company -> Released                       (run: error)
```

## Why it is not a provider lookup

`docs/workflows.md` specifies WF-03 against a paid provider, and the original
plan was Apollo. There is no budget for one until the first client pays, so this
version reads the company's own website instead.

That turns out to be the stronger position rather than a compromise. An address
a company publishes on its own contact page was put there to be written to,
which is the cleanest footing the legitimate-interest basis in
`docs/security.md` can have. A provider's record has no such provenance.

What it costs is coverage. Most company websites do not name their engineering
leadership, and finding nothing is the common outcome, not the exception.

## Three tiers of evidence

| Tier | `email_status` | `discovery_method` | What it means |
|---|---|---|---|
| Published | `valid` | `published_page` | The address is literally on a page the company publishes. `source_url` is that page. |
| Derived | `guessed` | `pattern_inferred` | Built from a pattern seen in a real address on the same domain. |
| Named only | `unknown` | `NULL` | A person exists, with no address. Still worth having: the pattern may reach them later, and WF-04 scores a named decision maker above nobody. |

`valid` here does **not** mean verified. Nothing in this system checks
deliverability - that costs money too. The migration says so on the column
itself, because a column whose meaning lives only in a workflow will be misread.

## The model proposes, the workflow enforces

The model transcribes a page. Everything it says is checked in
`Validate And Verify` against the text it was given:

| Check | Why |
|---|---|
| Every address must appear verbatim in the fetched pages | An address nobody published goes to a real person at a real company |
| Every address must be on the company's own domain | Footers carry the web agency's address, the hosting provider's, a press contact at an agency |
| Every name must appear verbatim in the fetched pages | An invented person cannot survive |
| A role address (`hello@`, `jobs@`, `sales@`) may never be a person | `people.full_name` is NOT NULL, and satisfying it would put "Careers team" in the greeting |
| A title not found on the page is dropped, the person is kept | A title is a claim that ends up in an email |
| `seniority` is re-derived from the title in code | The schema cannot enforce an enum - see `docs/ollama.md` |

Everything rejected is written to `agent_runs.output.dropped`. What a model
invented is as informative as what it read, and it is the only way to tell a
company with no published contacts from a model having a bad day.

Role addresses are verified and recorded in `agent_runs.output.role_addresses`,
never written to `people`. They are real and they are published; there is simply
no person behind them.

## Deriving an address

The one place an address is produced rather than read. It only happens when the
company's own site already showed one built the same way.

For every person whose published address is known, the local part is matched
against their name folded to ASCII - `Petrović` becomes `petrovic` - and the
first matching template wins, ordered most specific first:

```
first.last  f.last  first_last  first-last  firstlast  flast  last.first  lastf  first  last
```

Templates are tallied across every observed pair, not taken from the first one.
If two published addresses disagree about the pattern, **nothing is derived** and
the disagreement is recorded. A single address that disagrees with two others
loses to the majority.

A derived address gets the source URL of the page that **proved the pattern**,
not a page containing that address - there is none, and pretending otherwise
would make `source_url` a lie.

**There is no blind guessing.** No list of common templates is tried against a
domain that has never shown one. That was a deliberate choice, and the reason is
in `docs/security.md`: an address the system invented can belong to somebody
else, and "where did you get my details" is a question with a required answer.

## Fetching

Different pages from WF-02, because they are looking for different things:
`/contact`, `/team`, `/about`, `/people`, `/leadership`, `/careers`.

`robots.txt` is honoured with the same parser as WF-02 - literally the same
code, copied, with a comment on both saying so. The per-domain throttle from
`0012_fetch_throttle.sql` is shared with WF-02: the limit is per domain, not per
workflow.

`mailto:` links are pulled out of the **raw HTML** before tags are stripped.
WF-02's version of this node turns HTML into plain text first, which throws away
every `mailto:` href on the page - and a `mailto:` is the most reliable
published address there is, because a human put it there to be clicked.

Addresses written as `name (at) example (dot) com` are un-obfuscated. That is
reading what the page says, not defeating anything: the address is published and
the obfuscation is aimed at bulk harvesters.

## Status, and why not `ready`

`docs/workflows.md` has the company moving `enriching` then `ready`. It goes
back to **`researched`** instead.

`ready` is a dead end. WF-04 claims companies at `researched`, and WF-04 is what
turns a person into a lead, so a company parked at `ready` would have a contact
and never a lead. Going back to `researched` means the 15 minute scoring pass
picks it up, re-scores `decision_maker` from the `people` table, and creates the
lead. Finding nothing returns the company to `scored`, untouched.

## Not finding anybody

A normal outcome, and the common one. The run is closed as `skipped`, not
`error`: a company whose pages name nobody is not a fault, and recording it as
one would make WF-101's error rate meaningless.

The company is not looked at again for `ENRICH_RETRY_DAYS` (30). The
`agent_runs` row is that memory - there is no retry counter and no migration for
one, the same choice WF-02 makes about failures.

## Running it

Schedule, hourly, once activated. Three companies per pass, roughly 30 seconds
each on the small local model: enrichment transcribes rather than reasons, so
`OLLAMA_ENRICHMENT_MODEL` defaults to `llama3.1:8b` and not to the large one.

By hand: **Test workflow** in the UI. The CLI cannot start a schedule-triggered
workflow - `n8n/README.md` has the way round it.

## Verifying

```sql
SELECT p.full_name, p.title, p.email, p.email_status, p.discovery_method, p.source_url
FROM people p JOIN companies c ON c.id = p.company_id
ORDER BY c.name, p.full_name;

SELECT c.name, r.status, r.output -> 'pattern' AS pattern,
       r.output -> 'derived_count' AS derived,
       r.output -> 'dropped'       AS dropped,
       r.output -> 'notes'         AS notes
FROM agent_runs r JOIN companies c ON c.id = r.company_id
WHERE r.agent_name = 'enrichment'
ORDER BY r.started_at DESC;
```

`dropped` is the one to read first. An empty array on a company with several
people means the model transcribed cleanly. A long one means it is inventing,
and the prompt or the model is the thing to change.

## Measured

One company, a four-person team page with one published address, end to end:
**30 seconds**, 1727 prompt tokens, zero cost. One published contact, two
derived from the `first.last` pattern it proved, the marketing lead correctly
not returned, three role addresses recorded, the web agency's address on the
same page correctly refused. WF-04 then scored 82 / `HIGH_PRIORITY` and created
the lead on the CTO.
