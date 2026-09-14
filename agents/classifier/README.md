# classifier

**Workflow:** WF-08 Inbox Classifier
**Prompt:** `prompts/classifier.md`
**Model:** Ollama (`OLLAMA_MODEL`), escalating to the external LLM below 0.7
confidence

## Input

```json
{ "message_id": "uuid", "subject": "", "body": "", "from": "", "thread": [] }
```

## Output

`schema.json`. One of eight categories plus a calibrated confidence.

## Writes

- `messages.classification`, `messages.classification_confidence`
- `conversations.status`
- `leads.status`
- `suppression_list` on `UNSUBSCRIBE`

## Must never

- Miss an opt-out. `UNSUBSCRIBE` outranks every other category.
- Reply. This agent classifies; WF-09 replies.
- Act on a confidence below 0.7 without escalating first, then to a human.

## Order of operations on UNSUBSCRIBE

1. Insert into `suppression_list`
2. Cancel unsent `outreach` rows for the lead
3. Set conversation `unsubscribed`, lead `suppressed`
4. Log, and send nothing

## Failure modes

| Symptom | Cause | Response |
|---|---|---|
| Opt-out classified as NEGATIVE | Politeness misread as a soft no | Treat `requested_stop` as authoritative regardless of category. |
| Auto-replies classified as POSITIVE | Out-of-office boilerplate | Filter obvious auto-reply headers before the model sees it. |
| Confidence always 0.9+ | Uncalibrated local model | Check against a labelled set; escalation is useless if confidence is not real. |
