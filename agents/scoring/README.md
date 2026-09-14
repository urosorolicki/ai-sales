# scoring

**Workflow:** WF-04 Lead Scoring
**Prompt:** `prompts/scoring.md`
**Model:** external LLM (`LLM_MODEL`)

## Input

The research output for the company, plus its `signals` rows and its contact
rows from `people`.

## Output

`schema.json`. Six components with a reason each, plus the three column values.

## Writes

- `companies.fit_score`, `companies.research_score`,
  `companies.decision_maker_score`, `companies.status = 'scored'`
- `leads` - one row per contactable decision maker, with `score`, `reason` and
  `recommended_offer`

`companies.total_score` and `companies.score_band` are **generated columns**.
The agent must not write them. The workflow compares the model's `total_score`
against the database's and logs a mismatch through WF-99.

## Must never

- Award points for evidence that is not in the input.
- Score an absent field as average.
- Overwrite a band set by a hard override (suppressed, competitor, client).

## Failure modes

| Symptom | Cause | Response |
|---|---|---|
| Components do not sum to `total_score` | Model arithmetic | Database value wins; log the mismatch. |
| Everything scores 60-75 | Prompt drift toward the middle | Re-calibrate against the worked example; check absent evidence scores 0. |
| High score, `sources` empty upstream | Bad research accepted | Fix the research validation, not the scoring. |
