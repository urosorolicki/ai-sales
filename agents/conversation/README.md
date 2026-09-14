# conversation

**Workflow:** WF-09 Conversation Agent
**Prompt:** `prompts/conversation.md`
**Model:** external LLM (`LLM_MODEL`)

## Input

The full thread from `messages`, the lead, the research file, and the offer
table.

## Output

`schema.json`. Either a `reply` or an `escalate` with a reason - never both.

## Runs only on

Threads the classifier marked `QUESTION` or `PRICE`. `POSITIVE`, `NEGATIVE`,
`REFERRAL`, `NOT_NOW` and `UNSUBSCRIBE` never reach this agent.

## Writes

- `messages` (outbound, `author = 'agent'`)
- `conversations.status`, `conversations.escalation_reason`

## Hard limits enforced outside the model

The prompt states these, and the workflow checks them again before anything is
queued. A model that has been talked into breaking one must not be able to act
on it.

| Limit | Check |
|---|---|
| Max 10% discount | `price_quoted` parsed and compared to the offer table |
| Min EUR 500 | Any quoted figure below the floor blocks the message |
| No commitments | `commitments_made` non-empty routes to a human |
| No signing, no dates | Keyword check on the reply for contract and date language |
| No system changes | The agent has no credentials and no tools that could make one |

## Failure modes

| Symptom | Cause | Response |
|---|---|---|
| Agrees to a date | Model accommodating the prospect | Keyword check catches it; the reply is blocked, not edited. |
| Discount creep | Repeated pressure over several turns | Compare against the original offer, not the previous message. |
| Answers too long | Trying to demonstrate expertise | Cap and reject, do not summarise. |
| Invented reference or client | Model filling a credibility gap | Reject the run, and treat it as a prompt regression. |
