# WF-05 Outreach Generation

Writes the first email for a scored lead and stops at `pending_approval`.
Nothing it produces is ever sent without a human.

Artifact: `n8n/workflows/ai-sales-outreach-generation.json`
Prompt: `prompts/outreach.md` · Schema: `agents/outreach/schema.json`

```
Every Hour
  -> Read Outreach Prompt / Read Outreach Schema
  -> Claim Leads                       (score >= OUTREACH_MIN_SCORE, reachable, not suppressed, no step-1 draft)
  -> Build Outreach Request -> Outreach Agent
  -> Validate And Check -> Usable Response?
       +-- no  -> Close Run Error
       +-- yes -> Passed Checks?
                    +-- yes -> Queue For Approval        (outreach + lead to pending_approval)
                    |            +-> Queue Draft Alert   (the approval message, second branch)
                    +-- no  -> Store Blocked Or Skipped  (draft kept with the reason, or lead to nurture)
```

## The approval message

A queued draft also queues the notification `docs/telegram.md` specifies, with
the hook and its source **above** the email body - the one thing worth checking
is whether the claim is true, and that takes five seconds when the link is at the
top - and the whole body, because an approval on a summary is not an approval.

Everything except the hook is read back out of `v_approval_queue`, so the message
describes the row that was actually written rather than what the workflow
believes it wrote. If the draft is not there at `pending_approval`, the query
returns no rows and nothing is queued: a refused write, not a silent success.

It hangs off `Queue For Approval` as a **second branch**. `Close Run Success`
resolves `$('Validate And Check').item` by paired item, and inserting a node into
that chain would break the lineage. The audit trail must not depend on a
notification succeeding.

`docs/notifications.md` has the delivery half.

## The checks are mechanical

`prompts/outreach.md` has a list of hard rules and a longer list of phrases that
must never appear. `docs/workflows.md` names the checks as WF-05's job. They are
enforced in code, not requested in a prompt, and a draft that fails one is
**stored, not fixed**.

| Check | Blocks the draft when |
|---|---|
| Word ceiling | The body is over 120 words. Counted from the body, not taken from `word_count` |
| Banned phrases | "reaching out", "circling back", "hope this finds you well", "companies like yours", "leverage", "synergy" and the rest of the NEVER WRITE list |
| Calendar link | calendly, cal.com, savvycal, hubspot meetings, "book a call" |
| Emoji | Any emoji in the body or subject |
| One question | More than one `?` in the body |
| Hook is checkable | `hook_source` is empty, or is not one of the URLs the research actually found |
| Offer | Outside the three in the schema |
| Subject | Contains the recipient's first name |

Notes that do not block: a subject outside four to seven words, a body with no
question at all, a `word_count` that disagrees with the body, and an offer that
differs from the one scoring recommended.

**`hook_source` is the important one.** It exists so a human approving the draft
can check the single claim the message rests on in five seconds. The known
sources are assembled from the research run's `analysis.sources` and every
`signals.source_url` for that company. A hook pointing anywhere else cannot be
verified, which defeats the field, so it is blocked.

Nothing is edited to comply. A blocked draft is one a human can read and learn
from; a quietly corrected one teaches nobody anything.

### A schema value in the prose

The agent picks `recommended_service` from an enum, and one draft came back
reading "I run a bounded devops_improvement_sprint": the identifier itself,
inside the sentence, in a message addressed to a person. It passed every check
there was, because none of them looked for it.

Any snake_case token in the subject or body now blocks the draft. Nobody writes
an underscore in an email, so such a token is the model quoting its own schema
back at the reader. `docs/company-research.md` records the same failure in the
research agent, where `why_now` came back as
`active_hiring_for_infrastructure_fixes` instead of a sentence, so this is a
habit of the local models rather than a one-off.

## Three outcomes

| Outcome | `outreach` | `leads` | Run |
|---|---|---|---|
| `queued` | `pending_approval` | `pending_approval` | success |
| `blocked` | `draft` with `rejection_reason` | unchanged | success |
| `not_sending` | nothing | `nurture` | success |
| model error | nothing | unchanged, retried next hour | error |

`send: false` is a legitimate answer, not a failure - `prompts/outreach.md` says
sending nothing is always acceptable. The lead moves to `nurture` so it leaves
the queue instead of being regenerated every hour.

A blocked draft leaves the lead at `new`, but the unique index on
`(lead_id, sequence_step)` means the next pass updates that draft rather than
adding another.

## The recipient has to have an address

The claim query requires one: `p.email IS NOT NULL` and an `email_status` of
`valid`, `catch_all` or `guessed` - the same three the schema's
`people_contactable_idx` already calls contactable.

WF-04 checks this before it creates a lead, which looked like enough. It is not,
because the address can go away afterwards and the lead stays. Measured on
Adyen: WF-03 derived `pieter.does@adyen.com` for the chief executive at 06:00,
WF-04 created the lead on it at 06:15 and scored the decision maker 7 for an
address it called `guessed`, the address was withdrawn at 07:26 because his
surname is "van der Does" and no observed address on that domain proved the
form, and at 08:00 WF-05 wrote a draft for a lead with no recipient and queued
it for approval. A bounce clearing an address would do the same thing.

Nothing caught it downstream. `is_suppressed(NULL)` is false, so the claim's
suppression check passed; `outreach` stores no recipient column, so the trigger
had nothing to compare; and the approval message reads the row back out of
`v_approval_queue`, which shows the empty address rather than refusing.

## Suppression is enforced twice

The claim query skips suppressed recipients so they never cost a model call.
The `outreach_enforce_suppression` trigger on the table rejects the insert
outright if the workflow ever slips. Verified: inserting a draft for a
suppressed address raises `outreach blocked: <email> is on the suppression
list`.

## The worked example is left out of the prompt

`prompts/outreach.md` ends with a full example email. It is deliberately not
sent to the model: a local model copies an example rather than learning from it.
The system prompt, the structure, the subject-line rules and the offer table are
sent; everything from `## Example` onward is not.

## Running it

Schedule, hourly, once activated. By hand: open it and click **Test workflow**.

It needs a lead at `status = 'new'` with `score >= OUTREACH_MIN_SCORE`
(currently 60), which means a person, which means WF-03 - or a person inserted by
hand, which is what `docs/workflows.md` expects at this stage.

## Measured

Full chain on one company, all local, all free:

| Step | Model | Time |
|---|---|---|
| WF-02 triage | `llama3.1:8b` | 9s |
| WF-02 research | `qwen9-64k` | 135s |
| WF-04 scoring | `qwen9-64k` | 19s |
| WF-05 outreach | `qwen9-64k` | 15s |

Scored 93, band `HOT`, and the draft passed every check. What it wrote:

```
Subject: 45-minute builds blocking daily deploys

Your GitLab CI pipeline takes 45 minutes per the blog post on your site.

That latency forces a twice-a-week release cadence instead of daily. It also
means engineers are likely skipping safety checks or forgetting manual steps
during releases, as seen in recent incidents.

I can run an infrastructure audit to map where those build minutes go and
identify which Terraform modules need refactoring for EKS migration.

Is this a priority right now?
```

73 words, one question, hook sourced to the blog post it came from. That is a
draft worth reading, from a model that costs nothing to run.

The judgement to watch is "engineers are likely skipping safety checks" - an
inference, flagged as one by "likely", and sourced to the incidents the blog
actually describes. The line between that and an invented claim is exactly what
the human approval step is for.

## Not implemented

The daily send limit, the per-domain limit and the working-hours window are
WF-06's job, not this one. `OUTREACH_PAUSED` and `OUTREACH_AUTOSEND_ENABLED` are
not read here either: nothing in this workflow sends anything.
