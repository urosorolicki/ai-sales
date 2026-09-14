# Classifier agent

Used by **WF-08 Inbox Classifier**. Runs on every inbound message. Writes
`messages.classification` and drives the state change on `conversations`,
`leads` and, for opt-outs, `suppression_list`.

This is the highest-volume and lowest-latency agent in the system, so it runs
on the local Ollama model by default. It escalates to the external LLM only
when its own confidence is below 0.7.

---

## System prompt

```
You classify replies to cold outreach sent by a DevOps/SRE consultant.

Return exactly one category. Judge intent, not politeness. A warm, friendly
message that declines is NEGATIVE. A blunt one-line "how much?" is PRICE.

When a message could belong to two categories, use this precedence:

  UNSUBSCRIBE > NEGATIVE > REFERRAL > PRICE > QUESTION > NOT_NOW > POSITIVE > OUT_OF_SCOPE

Getting UNSUBSCRIBE wrong is the most expensive mistake available to you. If
there is any indication at all that the person wants no further contact,
classify it as UNSUBSCRIBE, whatever else the message also says.

Return valid JSON only, no prose, no markdown fences.
```

## Categories

| Category | Means | System action |
|---|---|---|
| `POSITIVE` | Interest, wants to talk, asks to book | Stop all automated outreach. `conversations.status = 'awaiting_human'`, lead -> `opportunity`, notify via Telegram. |
| `QUESTION` | Technical or scoping question, no commitment yet | Conversation agent may answer. |
| `PRICE` | Asks what it costs | Conversation agent may answer within the published ranges. |
| `NOT_NOW` | Interested in principle, wrong time | Cancel pending follow-ups, lead -> `nurture`, revisit date if one is given. |
| `NEGATIVE` | Not interested | Stop outreach. Lead -> `closed_lost`. Do not add to suppression unless they asked. |
| `REFERRAL` | Points at a colleague | Stop this thread. Create a task for a human; do not auto-contact the referred person in Phase 1-9. |
| `UNSUBSCRIBE` | Any request to stop contacting | Add to `suppression_list` immediately, stop everything, never contact again. |
| `OUT_OF_SCOPE` | Auto-reply, out-of-office, bounce, newsletter, spam, wrong person | No state change beyond logging. Out-of-office may carry a return date. |

## UNSUBSCRIBE

Treat all of these as UNSUBSCRIBE regardless of tone:

"unsubscribe", "remove me", "take me off your list", "stop emailing me",
"do not contact me again", "opt out", "this is spam", "I'm reporting this",
any mention of GDPR, CCPA, or a data-protection request, any legal threat,
or a reply that contains nothing but a link to an opt-out page.

Also UNSUBSCRIBE when the message is hostile enough that further contact would
be unwelcome, even without the word.

On UNSUBSCRIBE the workflow must, in this order and before anything else:

1. `INSERT INTO suppression_list (email, reason)` with `unsubscribe_request`.
2. Cancel every `outreach` row for that lead that is not yet `sent`.
3. Set the conversation to `unsubscribed` and the lead to `suppressed`.
4. Log it. Do not reply. Do not send a confirmation - it is another email.

The database trigger on `outreach` enforces this too, so a workflow bug
produces a failed insert rather than a second unwanted email.

## POSITIVE

Positive replies are where the automation stops and the human starts. Do not
let the conversation agent negotiate a first meeting on its own in the early
phases: set `awaiting_human`, notify, and let a person answer.

## Confidence

Return a calibrated `confidence` from 0.0 to 1.0. Below 0.7 the workflow
re-runs the classification on the external LLM. If it is still below 0.7, the
thread goes to `awaiting_human` rather than being acted on.

## Output schema

```json
{
  "category": "",
  "confidence": 0.0,
  "reason": "",
  "requested_stop": false,
  "mentioned_price": false,
  "mentioned_timeline": "",
  "referred_to": "",
  "suggested_next_action": "",
  "human_required": false
}
```

- `requested_stop` - true whenever the person asked for no further contact, even
  if the category ended up elsewhere. The workflow honours this flag on its own.
- `mentioned_timeline` - a date or relative period if the reply names one
  ("after Q1", "next year"), otherwise `""`. Drives when a `NOT_NOW` lead
  returns to the nurture queue.
- `human_required` - true for anything unusual: legal language, an existing
  relationship you did not know about, a complaint, an unclear identity, or
  anything you are not confident about.

## Examples

| Reply | Category | Notes |
|---|---|---|
| "Interesting - are you free Thursday?" | `POSITIVE` | Stop automation, notify. |
| "What would something like that cost?" | `PRICE` | Agent may answer with the range. |
| "We just hired someone for this, thanks." | `NEGATIVE` | Polite, still a no. |
| "Not now, maybe after Q1." | `NOT_NOW` | `mentioned_timeline` = "after Q1". |
| "Talk to Ana, she owns infra." | `REFERRAL` | Human handles the handover. |
| "Please remove me from your list." | `UNSUBSCRIBE` | Suppress immediately. |
| "Thanks but we're an agency, we do this ourselves." | `NEGATIVE` | Consider a competitor override on the company. |
| "I am out of office until 3 March." | `OUT_OF_SCOPE` | Reschedule the follow-up past that date. |
| "How do you handle state during a node roll?" | `QUESTION` | Genuine technical question, answer it. |
| "Unsubscribe. Also, this is illegal under GDPR." | `UNSUBSCRIBE` | Suppress, and `human_required` = true. |
