# Lead scoring

The rubric the scoring agent applies is in `prompts/scoring.md`. This document
is the reference for how the score is stored, computed and used.

## 100 points

| Component | Max | Stored in |
|---|---|---|
| Company fit | 20 | `companies.fit_score` |
| Technology fit | 20 | `companies.fit_score` |
| Hiring signal | 20 | `companies.research_score` |
| Pain evidence | 20 | `companies.research_score` |
| Decision maker | 10 | `companies.decision_maker_score` |
| Commercial potential | 10 | `companies.fit_score` |

Three stored columns, six components:

```
fit_score            = company_fit + technology_fit + commercial_potential   (0-50)
research_score       = hiring_signal + pain_evidence                         (0-40)
decision_maker_score = decision_maker                                        (0-10)
```

`companies.total_score` and `companies.score_band` are **generated columns**.
The agent writes the three components; PostgreSQL computes the total and the
band. They cannot disagree, and a workflow cannot write a band that does not
match its own numbers.

## Bands

| Total | Band | What happens |
|---|---|---|
| 0-39 | `IGNORE` | Nothing further. No enrichment, no draft, no cost. |
| 40-59 | `NURTURE` | Kept. Re-scored in 90 days. No outreach. |
| 60-74 | `OUTREACH` | Enriched, drafted, queued for approval. |
| 75-89 | `HIGH_PRIORITY` | Same, at the top of the approval queue. |
| 90-100 | `HOT` | Same, plus a Telegram notification on reaching the band. |

`OUTREACH_MIN_SCORE` (default 60) is the floor for generating a draft at all.
It is separate from the bands so the threshold can be raised without changing
the rubric.

## Hard overrides

Applied by WF-04 after the model returns, regardless of the total:

| Condition | Effect |
|---|---|
| Domain or email on `suppression_list` | `companies.status = 'suppressed'`, no lead created |
| Sells DevOps/SRE/platform consulting | Forced `IGNORE` |
| Existing or former client | Forced `IGNORE`, handled by a human |
| Research `confidence` below 0.3 | Total capped at 39 until re-researched |
| No contactable person | A lead may exist but cannot reach `OUTREACH` |

## Calibration

The rubric is only useful if it separates. Two failure modes to watch for, both
visible in one query:

```sql
SELECT score_band, count(*), round(avg(total_score)) AS avg
FROM companies
WHERE score_band <> 'UNSCORED'
GROUP BY score_band ORDER BY avg;
```

**Everything clusters at 60-75.** The model is scoring absent evidence as
average instead of zero. Re-read the "absent evidence scores zero" instruction
and check the worked example still produces 75.

**Nothing scores above 50.** Either discovery is feeding the wrong companies,
or research is not finding material that exists. Check `agent_runs` for
research runs with empty `sources` before touching the rubric.

The number that matters is not the average score. It is the proportion of
`OUTREACH` and above that a human actually approves. If approvals run below
about half, the scoring is too generous no matter what the distribution looks
like.

## Re-scoring

A nightly sweep re-scores companies whose evidence changed: a new signal, a new
contact, or research older than 90 days. Scores go down as often as up - a
hiring signal from a role that has since been filled should stop being worth 18
points, and nothing else in the system will notice if the sweep does not run.
