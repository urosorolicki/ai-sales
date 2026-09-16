# Telegram control plane

**Status: notifications are built, commands are not.** WF-10 delivers everything
in the notification outbox (`docs/notifications.md`); nothing yet reads a message
*from* Telegram, so none of the commands below work. This document specifies the
whole thing and marks what exists.

Telegram is the only human interface. There is no web UI and there should not
be one: the interactions are approve, reject, pause and look at a number, and
all four work better from a phone than from a dashboard nobody opens.

## Setup

1. Create a bot with `@BotFather` and copy the token.
2. In the n8n UI, **Credentials > New > Telegram API**, paste the token, and name
   it exactly **`Telegram account`**. WF-10's Send Telegram node already points
   at that name.
   The token deliberately does **not** go into `TELEGRAM_BOT_TOKEN`. An HTTP node
   would put it in the URL of every saved execution; a credential is encrypted by
   n8n and redacted from execution data. `docs/security.md` forbids the first.
3. **Press Start in a chat with your own bot**, or send it any message. This is
   not optional and it is not the same as step 1: a bot cannot open a
   conversation, so until the recipient has spoken to it first, every send comes
   back `400 Bad Request: chat not found` no matter how correct the token and
   the chat id are. Talking to `@userinfobot` to read your id does not count -
   that is a different bot.
4. Put the chat id in `TELEGRAM_CHAT_ID` and set `TELEGRAM_ENABLED=true`. WF-10
   claims nothing at all until both are set.
5. Recreate the n8n container: `docker compose up -d n8n`. Not `restart` - that
   reuses the old environment, and the container is where `$env` is read from.

Before the first delivery, look at what is already queued - otherwise the first
pass sends the entire backlog in one go:

```sql
SELECT kind, priority, occurrences, first_seen_at, title
FROM v_pending_notifications;
```

## Authorisation

**Every update is checked against `TELEGRAM_CHAT_ID` before anything happens.**
A message from any other chat is ignored silently - not answered, not logged as
an error, ignored. The bot token is a bearer credential: anyone who obtains it
can message the bot, and chat id matching is what stops that from mattering.

Commands that change state (`/approve`, `/reject`, `/pause`, `/resume`) are
recorded with the chat id and timestamp, because "who approved this" is a
question that gets asked after something goes wrong.

## Commands

**None of these are implemented.** They need a Telegram Trigger and the chat id
check above, and neither exists yet.

| Command | Does | Reads |
|---|---|---|
| `/status` | Stack health and current counts | `v_daily_stats`, health check |
| `/leads` | The approval queue, highest score first | `v_approval_queue` |
| `/hot` | Companies at `HIGH_PRIORITY` and `HOT` | `v_hot_companies` |
| `/today` | Today's activity: discovered, researched, drafted, sent, replies | `v_daily_stats` |
| `/approve <id>` | Approve one draft for sending | writes `outreach` |
| `/reject <id>` | Reject one draft with an optional reason | writes `outreach` |
| `/pause` | Stop all outbound immediately | sets `OUTREACH_PAUSED` |
| `/resume` | Resume outbound | clears `OUTREACH_PAUSED` |

Later, once the earlier phases have earned it:

| Command | Does |
|---|---|
| `/company <domain>` | The research file and signals for one company |
| `/thread <id>` | Full conversation history |
| `/suppress <email or domain>` | Add to the suppression list immediately |
| `/stats [7d\|30d]` | Conversion by stage over a period |

## Approval flow

WF-05 produces a draft and queues one message. **Built**, except the last line:
`Queue Draft Alert` composes this from `v_approval_queue`, so it describes the
row that was actually written rather than what the workflow believes it wrote.

```
[HIGH_PRIORITY 78]  Example Scaleup  (example.org)
Demo Person, VP Engineering
Offer: infrastructure_audit

Hook: platform engineer role open 68 days, EKS migration in progress
Source: https://example.org/careers/platform

Subject: eks migration, 68 days into the platform hire

Your platform engineer role has been open since July and the
description says the EKS migration is already underway.
...

id 7f3a  ·  approve and reject still happen in the database; the
Telegram commands are not built yet
```

The last line is not what this document specifies, on purpose. Printing
`/approve 7f3a` when nothing handles it is worse than printing nothing: it reads
as a working control. It goes back to `/approve 7f3a   /reject 7f3a` when the
commands exist.

Design rules for that message, all of which exist because the alternative was
tried by someone else and failed:

- **The hook and its source come before the email body.** The one thing worth
  checking is whether the claim is true, and it takes five seconds if the link
  is at the top.
- **The whole body is shown.** An approval on a summary is not an approval.
- **The id is short.** It gets typed on a phone.
- **Approve and reject are equally easy.** Rejection is the more common and more
  valuable action early on, and a flow that makes it harder quietly biases
  toward sending.

## Notifications

| Event | Priority | Content | Status |
|---|---|---|---|
| Positive reply | Immediate | Company, person, the reply, the thread, the research | needs WF-08 |
| Conversation escalated | Immediate | Why it escalated and the full thread | needs WF-09 |
| Company reaches `HOT` | Immediate | Company, score, the signals that got it there | **built** (WF-04) |
| Draft ready for approval | Batched | The approval message above | **built** (WF-05), one message per draft |
| Daily report | Once a day | `v_daily_stats` | **built** (WF-100) |
| Agent failure | Deduplicated | What failed, how many times, when it started | **built** (WF-99, WF-101) |

Deduplication matters more than it sounds like it does. A schedule that runs
every 15 minutes and fails every time will send 96 identical messages in a day,
and the result is that all Telegram notifications get muted - including the
positive reply.

It is enforced in the database, in `queue_notification()`, so no workflow can
skip it. `docs/notifications.md` has the rule and the four cases.

## What Telegram must never do

- **Never send outreach directly.** `/approve` changes a row to `approved`. WF-06
  sends, on its own schedule, with its own limit checks. The approval and the
  send stay separate so the limits cannot be bypassed by approving faster.
- **Never accept a command from an unknown chat id.**
- **Never include credentials, API keys or full error payloads** in a message.
- **Never be the only record.** Everything a command does is a database state
  change, so the state survives Telegram being unavailable. This is why
  notifications are a table that WF-10 drains rather than a send at the point
  the event happens: WF-04 does not lose a HOT company because a bot token is
  missing.
