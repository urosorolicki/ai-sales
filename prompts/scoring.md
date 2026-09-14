# Scoring agent

Used by **WF-04 Lead Scoring**. Reads the research output and the `signals`
rows; writes `companies.fit_score`, `companies.research_score`,
`companies.decision_maker_score` and the `leads` row.

`companies.total_score` and `companies.score_band` are generated columns - the
agent must never write them. Write the three components and let the database
compute the rest, so the band can never disagree with the parts.

---

## The rubric: 100 points

| Component | Max | Column |
|---|---|---|
| Company fit | 20 | `fit_score` |
| Technology fit | 20 | `fit_score` |
| Hiring signal | 20 | `research_score` |
| Pain evidence | 20 | `research_score` |
| Decision maker | 10 | `decision_maker_score` |
| Commercial potential | 10 | `fit_score` |

`fit_score` = company fit + technology fit + commercial potential (0-50)
`research_score` = hiring signal + pain evidence (0-40)
`decision_maker_score` = decision maker (0-10)

### Company fit (20)

| Points | Condition |
|---|---|
| 18-20 | 20-200 engineers, product company, ships continuously, no dedicated platform team |
| 13-17 | 10-500 engineers, software-centric, platform ownership unclear |
| 7-12 | Software is important but not the product, or size unknown |
| 1-6 | Non-technical business, or an agency/consultancy that sells the same service |
| 0 | Under 5 people, a competitor, or already suppressed |

Large enterprises score low here on purpose: they have internal platform teams
and a procurement process that a solo consultant cannot economically enter.

### Technology fit (20)

| Points | Condition |
|---|---|
| 18-20 | Kubernetes, or an active migration toward containers, plus cloud |
| 13-17 | Cloud plus Docker plus IaC, no Kubernetes yet |
| 7-12 | Cloud only, or a stack visible but shallow |
| 1-6 | Managed PaaS end to end, little to operate |
| 0 | No technology evidence at all |

Only count technology with a source. An empty `technology` array scores 0.

### Hiring signal (20)

| Points | Condition |
|---|---|
| 18-20 | Open senior DevOps/SRE/platform role, posted within 60 days |
| 13-17 | Open infrastructure-adjacent role, or a DevOps role older than 60 days |
| 8-12 | Engineering headcount growing fast, no infra role specifically |
| 3-7 | Careers page shows engineering hiring, nothing infra-specific |
| 0 | No hiring evidence |

A long-open senior DevOps role is one of the strongest signals in the system:
they have the need, the budget and no one to fill it.

### Pain evidence (20)

| Points | Condition |
|---|---|
| 18-20 | Public, dated, specific: an incident write-up, a cost post, a stated migration in trouble |
| 13-17 | Clear stated problem in a job advert ("help us reduce our 45-minute build") |
| 8-12 | Structural pain inferred from a mismatch: complex infra, small team |
| 3-7 | Weak or undated indications |
| 0 | None, or only inference with no underlying fact |

`reasonable_inferences` can reach at most 12 here. Above that requires a fact
with a source.

### Decision maker (10)

| Points | Condition |
|---|---|
| 9-10 | Named CTO/VP Eng/Head of Platform with a verified email |
| 6-8 | Named decision maker, email guessed or catch-all |
| 3-5 | Role identified, person not |
| 0 | No route to anyone who could decide |

### Commercial potential (10)

| Points | Condition |
|---|---|
| 9-10 | Funded or profitable, size supports a retainer |
| 6-8 | Can plausibly afford an audit and a sprint |
| 3-5 | Could afford an audit only |
| 0 | Cannot plausibly pay, pre-revenue, or a non-paying sector |

## Bands

| Total | Band | Action |
|---|---|---|
| 0-39 | `IGNORE` | No further spend. Do not enrich, do not draft. |
| 40-59 | `NURTURE` | Keep, re-check in 90 days. No outreach. |
| 60-74 | `OUTREACH` | Enrich contacts, draft, queue for human approval. |
| 75-89 | `HIGH_PRIORITY` | Same, moved to the top of the approval queue. |
| 90-100 | `HOT` | Same, plus a Telegram notification when the band is reached. |

## Hard overrides

Applied after scoring. These set the band regardless of the total:

- Domain or email on `suppression_list` -> company `status = 'suppressed'`, no lead.
- Competitor (sells DevOps/SRE/platform consulting) -> `IGNORE`.
- Existing or former client -> `IGNORE`, handled by a human.
- Research `confidence` below 0.3 -> cap the total at 39 until re-researched.
- No contactable person -> the lead may exist but cannot reach `OUTREACH`.

## System prompt

```
You are scoring a company as a prospect for a senior DevOps/SRE consultant.

Apply the rubric in this document literally. Award points only for evidence
present in the supplied research output. Absent evidence scores zero - it never
scores "average".

You are calibrating a machine that will spend money and someone's attention. A
score that is too generous is more expensive than one that is too harsh,
because it produces an email to a company that did not need one.

Return valid JSON only, no prose, no markdown fences:

{
  "company_fit": { "points": 0, "reason": "" },
  "technology_fit": { "points": 0, "reason": "" },
  "hiring_signal": { "points": 0, "reason": "" },
  "pain_evidence": { "points": 0, "reason": "" },
  "decision_maker": { "points": 0, "reason": "" },
  "commercial_potential": { "points": 0, "reason": "" },
  "fit_score": 0,
  "research_score": 0,
  "decision_maker_score": 0,
  "total_score": 0,
  "band": "",
  "recommended_offer": "",
  "reason": "",
  "overrides_applied": []
}

`reason` is one sentence, written for a human deciding whether to approve an
email. It must name the specific evidence, not the score.

`total_score` and `band` are returned for logging and for the workflow to
cross-check. The database recomputes both; if they disagree, the database wins
and WF-99 raises the mismatch.
```

## Worked example

Research shows: 60-person B2B SaaS, AWS and Docker sourced from job adverts,
open "Senior DevOps Engineer" posted 71 days ago naming Kubernetes as
"migration in progress", one blog post about a four-hour outage eight months
ago, named VP Engineering with a guessed email, Series A eighteen months ago.

| Component | Points | Why |
|---|---|---|
| Company fit | 18 | 60 engineers, product company, no platform team visible |
| Technology fit | 16 | Cloud + Docker sourced; Kubernetes stated but not yet in production |
| Hiring signal | 15 | Senior DevOps role open, but older than 60 days |
| Pain evidence | 11 | Outage is real but eight months old; migration pain is inferred |
| Decision maker | 7 | VP Engineering named, email guessed |
| Commercial potential | 8 | Series A, 60 engineers |

`fit_score` 42, `research_score` 26, `decision_maker_score` 7, total **75** ->
`HIGH_PRIORITY`, offer `infrastructure_audit`.
