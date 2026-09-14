# research

**Workflow:** WF-02 Company Research
**Prompt:** `prompts/research.md`
**Model:** external LLM (`LLM_MODEL`)

## Input

```json
{ "company_id": "uuid", "name": "", "domain": "", "website": "" }
```

Plus fetched material: careers page, engineering blog, public repos, about page,
any job adverts found. Fetching is the workflow's job, not the agent's.

## Output

`schema.json`. Separates `facts` (sourced), `reasonable_inferences` (derived)
and `unknown` (absent).

## Writes

- `companies`: `description`, `industry`, `employee_count`, `country`,
  `tech_stack`, `hiring_signals`, `pain_signals`, `status = 'researched'`
- `signals`: one row per item in `pain_signals` and `hiring_signals`, with the
  source URL. The unique index on `(company_id, signal_type, md5(signal))`
  makes re-running safe.

## Must never

- Invent a fact, a source, or a date.
- Put an inference in `facts`.
- Treat an integrations page or a customer logo as evidence of internal stack.

## Failure modes

| Symptom | Cause | Response |
|---|---|---|
| Empty output, confidence 0 | No public material | Not an error. Score will be `IGNORE`. |
| Schema validation fails | Model returned prose or a fence | Retry once, then `agent_runs.status = 'error'`. |
| Fetch blocked / 403 | Bot protection | Record which sources failed in `unknown`; do not retry aggressively. |
| Sources empty but facts present | The model invented them | Reject the whole run. This is the failure that matters. |
