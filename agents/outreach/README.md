# outreach

**Workflow:** WF-05 Outreach Generation
**Prompt:** `prompts/outreach.md`
**Model:** external LLM (`LLM_MODEL`)

## Input

The lead, the person, the company, the research file, and the thread so far for
a follow-up.

## Output

`schema.json`. Note `send`, which may be `false` - the agent is expected to
decline when the evidence does not support a specific message.

## Writes

`outreach` with `status = 'draft'`, then `pending_approval` once the workflow's
own checks pass:

- `word_count` <= 120
- `hook_source` is a non-empty URL that appears in the research `sources`
- no phrase from the banned list appears in the body
- the person is not suppressed (the database trigger enforces this as well)

## Must never

- Send. This agent produces rows; WF-06 sends.
- Quote a price in a first message.
- Include a fact that is not in the research file.
- Produce a follow-up whose only content is that a previous email exists.

## Failure modes

| Symptom | Cause | Response |
|---|---|---|
| `send: false` on most leads | Research is too thin | Correct behaviour: fix discovery and research, not this prompt. |
| Generic openers appearing | Prompt drift | The banned-phrase check should have caught it; extend the list. |
| Word count creeping up | Model verbosity | Hard reject above 120 in the workflow, do not trim automatically. |
