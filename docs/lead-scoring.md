# WF-04 Lead Scoring

Turns a researched company into three score columns and, when there is someone
to contact, a `leads` row.

Artifact: `n8n/workflows/ai-sales-lead-scoring.json`
Rubric: `prompts/scoring.md` · Schema: `agents/scoring/schema.json`
Reference: `docs/scoring.md`

```
Every 15 Minutes
  -> Read Scoring Prompt / Read Scoring Schema     (both from disk)
  -> Claim And Open Run                            (claim + open the run in one statement)
  -> Build Scoring Request -> Scoring Agent        (local, ~13s)
  -> Validate And Guard -> Scoring Valid?
       +-- true  -> Write Scores -> Close Run Success -> Scored
       +-- false -> Close Run Error
```

## The model proposes, the workflow enforces

The local model's evidence extraction is decent and its judgement is not
calibrated - `docs/company-research.md` has the measurements. Scoring is
judgement, so it would be the worst place to trust it.

The rubric in `prompts/scoring.md` already states rules that are checkable
against the database. Those are **enforced in code, not requested in a prompt**,
which is the same choice `docs/architecture.md` makes about the database: a
workflow bug should produce a refused write, not a wrong outcome.

| Rubric says | Enforced as |
|---|---|
| "Only count technology with a source. An empty `technology` array scores 0." | `technology_fit` capped at 0 unless a `tech_stack` entry has a `source` |
| "`reasonable_inferences` can reach at most 12. Above that requires a fact with a source." | `pain_evidence` capped at 12 unless a `signals` row has a `source_url`; capped at 0 with no signals |
| "18-20: open senior DevOps/SRE/platform role, posted within 60 days" | `hiring_signal` capped at 17 without a dated senior infrastructure role inside 60 days; 0 with no hiring signals |
| Decision maker 0-10, by whether a person and a verified email exist | **Replaced**, not capped: it is a property of the `people` table, not a judgement |

Every cap is written to `agent_runs.output.overrides` with the before and after
value, so a score can be explained months later.

Two fields are recorded but **not used**:

- `total_score` - `companies.total_score` and `score_band` are generated columns.
  The workflow writes the three components and the database computes the rest, so
  a band can never disagree with its own parts. A disagreement with the model's
  own arithmetic is noted, not corrected; `docs/scoring.md` says the database
  value stands.
- `recommended_offer` - carried through from the research run, which already
  chose one and had it validated against the enum. Asking a second model for it
  only adds a way to be wrong.

Both of those matter because **the JSON Schema constrains keys and types but not
enums or numeric bounds.** In a real run this model returned `total_score: 109`
and put a score band in the offer field. Nothing downstream may depend on a value
the schema cannot actually police.

## Hard overrides

From `docs/scoring.md`, applied after the components are settled:

| Condition | Effect |
|---|---|
| Domain on `suppression_list` | `status = 'suppressed'`, total forced to 0, **no lead row at all** |
| Description matches a DevOps/SRE/platform consultancy | total capped at 39 (`IGNORE`) |
| Research `confidence` below 0.3 | total capped at 39 until re-researched |
| No person on file | `decision_maker` is 0 and no lead is created |

When a cap applies, `research_score` is reduced first and `fit_score` second. If
the cap is there because the evidence is not trustworthy, the evidence-derived
half is the half to discount.

## Claiming

`companies` has no `scoring` status and inventing one would mean a migration for
a transient state. The `agent_runs` row **is** the claim: a company with a
scoring run still at `running` is skipped, and the check is windowed to 15
minutes so a run that died without WF-99 closing it does not block the company
forever. `FOR UPDATE SKIP LOCKED` sits on top, and the claim and the run are
opened in a single statement so there is no gap between them.

`docs/workflows.md` has WF-02 calling this workflow on completion. It polls
instead: PostgreSQL is the queue (`docs/architecture.md`), and a scoring failure
must not be able to fail a research run.

## Leads

A lead needs a person, and `people` is filled by WF-03, which does not exist. So
today WF-04 writes scores and creates no leads, which is the documented outcome
of "no contactable person" rather than a bug. The note lands in
`agent_runs.output.notes`.

When people do exist, the insert is `ON CONFLICT (company_id, person_id) DO
UPDATE`, so re-scoring moves a lead's score instead of duplicating it.

## Running it

Schedule, every 15 minutes, once activated. By hand: open it and click **Test
workflow** - the CLI cannot start a schedule-triggered workflow.

Five companies per run, set in the `Claim And Open Run` node. At roughly 15
seconds each that is comfortable inside the schedule.

## Verifying

```sql
SELECT c.name, c.fit_score, c.research_score, c.decision_maker_score,
       c.total_score, c.score_band, c.status,
       r.output -> 'overrides' AS overrides
FROM companies c
LEFT JOIN LATERAL (
    SELECT * FROM agent_runs
    WHERE company_id = c.id AND agent_name = 'scoring' AND status = 'success'
    ORDER BY started_at DESC LIMIT 1
) r ON true
ORDER BY c.total_score DESC NULLS LAST;
```

`docs/scoring.md` has the calibration query and what its two failure shapes mean.

## Measured

One company, real research output, end to end: **15 seconds**, components
18/19/17/19/7/9, stored total 89, band `HIGH_PRIORITY`, one lead written.

Scoring sends `reasoning_effort: "none"`. The qwen models otherwise spend their
whole budget thinking - 25000 characters of reasoning against 1000 of answer, and
218 seconds against 13 - and the component scores are no better for it. Research
keeps reasoning on, where turning it off costs six required keys. See
`docs/ollama.md`.

## Known weakness

In the run above, `hiring_signal` was capped from 20 to 17 because the research
agent had not recorded a `posted_at`, even though the careers page carried a
date. The cap is correct - undated evidence cannot earn the top band - but the
points were lost to a research shortcoming, not to the company.

`posted_at` is optional in `agents/research/schema.json`. Making it required
would force the model to invent dates, which is worse. The honest fix is a
better research model.
