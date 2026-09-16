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
       +-- true  -> Write Scores -> Close Run Success -+-> Scored
       |                                               +-> Reached HOT? -> Queue Hot Alert
       +-- false -> Close Run Error

Nightly Sweep (03:20)
  -> Requeue Stale Scores -> Sweep Result
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

A lead needs a person **with a usable address**. WF-03 writes people it found
named on a team page with no address at all, so "there is a person" and "there
is somebody to write to" are different questions.

Without the address check the lead would still be created, WF-05 would draft for
it, and the draft would reach `pending_approval` with no recipient:
`is_suppressed(NULL)` is false and the trigger on `outreach` has nothing to
compare. The check belongs here, where the lead is created.

The recipient is chosen deliberately rather than taken first, because the order
`people` comes back in means nothing:

1. **Is this a decision maker at all.** A published address on a junior engineer
   is still the wrong person to write to.
2. **How the address was obtained.** `docs/security.md` treats a bounce as
   unrecoverable damage to the sending domain, so a published address beats one
   this system derived.
3. **Seniority**, as the tiebreak.

Taking the first row cost a CTO with a published address the lead, which went to
a VP with a derived one purely by position in the array. That was found by
running it, not by reading it.

The insert is `ON CONFLICT (company_id, person_id) DO UPDATE`, so re-scoring
moves a lead's score instead of duplicating it.

## The nightly sweep

Scoring is not a one-off verdict. Two things make an old score wrong:

- **A contact appears.** `decision_maker_score` is a property of the `people`
  table rather than a judgement, so a company that had nobody on file is scored
  differently the moment WF-03 finds someone - and that is also the moment its
  first lead can exist.
- **Age.** Evidence goes stale. `RESCORE_AFTER_DAYS` defaults to 7.

The sweep does not re-score anything itself. It moves companies from `scored`
back to `researched` and the 15 minute pass above picks them up, so there is
exactly one scoring path and no second copy of the guards to keep in step.

`IGNORE` companies are skipped unless somebody was added to them. Re-scoring a
company that was capped to `IGNORE` spends a model call to reach the same
answer; a new contact is the one thing that can change it.

The requeue is re-checked against `status = 'scored'` inside the UPDATE, so two
overlapping sweeps cannot both claim a row, and a second run finds nothing.

## Reaching HOT

`docs/telegram.md` lists "company reaches HOT" as an immediate notification.
`Reached HOT?` reads `score_band` from `Write Scores`, which is the value the
database generated - not the model's arithmetic, which `docs/scoring.md` says
never wins.

The alert hangs off `Close Run Success` as a **second branch** rather than
sitting inside the chain. `Scored` reads `$json.duration_ms` from `Close Run
Success` and resolves `$('Write Scores').item` by paired item; routing it through
two more nodes would break both. A notification is not worth a regression in the
path that writes the score.

The message carries the top five signals with their source URLs, and says
explicitly when there is no contact on file - which today is always, because
WF-03 does not exist. Deduplicated on the company for `HOT_ALERT_COOLOFF_DAYS`
(30), so a company that is re-scored nightly and stays HOT is not news twice.

## Running it

Schedule, every 15 minutes, once activated, plus the sweep at 03:20. By hand:
open it and click **Test workflow** - the CLI cannot start a schedule-triggered
workflow (`n8n execute` answers "Missing node to start execution"). To run one
from the CLI anyway, import a copy whose trigger is a Manual Trigger, execute
that by id, and delete it afterwards.

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
