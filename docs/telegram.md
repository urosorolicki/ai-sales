# Telegram control plane

**Status: Phase 3. Not implemented.** This document specifies it.

Telegram is the only human interface. There is no web UI and there should not
be one: the interactions are approve, reject, pause and look at a number, and
all four work better from a phone than from a dashboard nobody opens.

## Setup

1. Create a bot with `@BotFather`, take the token into `TELEGRAM_BOT_TOKEN`.
2. Send the bot a message, read the chat id, put it in `TELEGRAM_CHAT_ID`.
3. Set `TELEGRAM_ENABLED=true`.

## Authorisation

**Every update is checked against `TELEGRAM_CHAT_ID` before anything happens.**
A message from any other chat is ignored silently - not answered, not logged as
an error, ignored. The bot token is a bearer credential: anyone who obtains it
can message the bot, and chat id matching is what stops that from mattering.

Commands that change state (`/approve`, `/reject`, `/pause`, `/resume`) are
recorded with the chat id and timestamp, because "who approved this" is a
question that gets asked after something goes wrong.

## Commands

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

WF-05 produces a draft and sends one message:

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

/approve 7f3a   /reject 7f3a
```

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

| Event | Priority | Content |
|---|---|---|
| Positive reply | Immediate | Company, person, the reply, the thread, the research |
| Conversation escalated | Immediate | Why it escalated and the full thread |
| Company reaches `HOT` | Immediate | Company, score, the signals that got it there |
| Draft ready for approval | Batched | The approval message above |
| Daily report | Once a day | `v_daily_stats` |
| Agent failure | Deduplicated | What failed, how many times, when it started |

Deduplication matters more than it sounds like it does. A schedule that runs
every 15 minutes and fails every time will send 96 identical messages in a day,
and the result is that all Telegram notifications get muted - including the
positive reply.

## What Telegram must never do

- **Never send outreach directly.** `/approve` changes a row to `approved`. WF-06
  sends, on its own schedule, with its own limit checks. The approval and the
  send stay separate so the limits cannot be bypassed by approving faster.
- **Never accept a command from an unknown chat id.**
- **Never include credentials, API keys or full error payloads** in a message.
- **Never be the only record.** Everything a command does is a database state
  change, so the state survives Telegram being unavailable.
