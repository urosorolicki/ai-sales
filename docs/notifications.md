# Notifications

Every alert this system produces is a database row first and a Telegram message
second. That order is the whole design, and it comes straight out of
`docs/telegram.md`: **Telegram must never be the only record.**

The consequence is that nothing in the pipeline has to know whether Telegram is
configured, reachable, or rate limited. WF-99 does not fail because a bot token
is missing. WF-04 does not lose a HOT company because Telegram is down. They
write a row; delivery is somebody else's problem.

Migration: `postgres/migrations/0011_notifications.sql`
Delivery: `n8n/workflows/ai-sales-telegram-dispatch.json` (WF-10)

```
WF-99  ──┐
WF-04  ──┤
WF-05  ──┼──> queue_notification() ──> notifications ──> WF-10 ──> Telegram
WF-101 ──┤                                (the record)   (every 5 min)
WF-100 ──┘
```

## Deduplication

`docs/workflows.md` requires it on WF-99: one broken schedule must not send 96
messages a day. `docs/telegram.md` explains why it matters more than it sounds
like it does - the real failure is not the noise, it is that the noise gets the
channel muted, and then the positive reply goes unread too.

The rule lives in one place, `queue_notification()`, and a unique index on
`dedup_key` means no workflow can write a second row for the same alert even if
it tries. Callers do not implement it and cannot opt out of it.

Four cases, decided in this order:

| State of the existing row | What happens |
|---|---|
| `pending` / `sending` / `failed` | Count it, refresh the text. Still undelivered, so the message that eventually goes out describes the latest instance. |
| `sent`, inside the cooloff | Count it, stay quiet. **This is the case that stops the 96 messages.** |
| `sent`, cooloff expired | A new episode: counter and start time reset, status back to `pending`. |
| `suppressed` | Count it, never re-open. Muting is a human decision and nothing undoes it automatically. |

`occurrences` and `first_seen_at` are what let a message say "7 times, first 3h
ago", which is the shape `docs/telegram.md` asks for.

### What counts as "the same alert"

Whatever the caller puts in `dedup_key`. The convention is
`<kind>:<stable discriminator>`:

| Source | Key | Cooloff |
|---|---|---|
| WF-99 failure | `agent_failure:<workflow id>:<node>:<fingerprint>` | `ALERT_COOLOFF_MINUTES` (60) |
| WF-101 health | `agent_health:<check>[:<agent>]` | `HEALTH_ALERT_COOLOFF_MINUTES` (360) |
| WF-04 HOT | `company_hot:<company id>` | `HOT_ALERT_COOLOFF_DAYS` (30) |
| WF-05 draft | `draft_ready:<outreach id>` | 7 days |
| WF-100 report | `daily_report:<date>` | 1 day |

WF-99's fingerprint is the interesting one. The error **message** cannot be part
of the identity, because a timeout that names a different company, or a row
count that ticks up, is the same fault. So the message is reduced: UUIDs and
numbers are replaced with placeholders, whitespace is collapsed, and what
remains is the shape of the error. It is computed from the *redacted* message,
so no credential reaches the key either.

The daily report goes the other way and puts the date **in** the key, so each
day is a new row and a re-run inside the same day is folded rather than sent
twice. That is the idempotency rule from `docs/workflows.md` in one line.

## Delivery: WF-10

| | |
|---|---|
| Trigger | Schedule, every 5 minutes |
| Guard | Runs only if `TELEGRAM_ENABLED` is exactly `"true"` **and** `TELEGRAM_CHAT_ID` is set |
| Input | `pending`, retryable `failed`, and stale `sending` rows, highest priority first |
| Output | Telegram message; `notifications.status` to `sent` or `failed` |

```
Every 5 Minutes -> Telegram Configured?
     +-- false -> Not Configured            (nothing is claimed)
     +-- true  -> Claim Notifications -> Format Message -> Send Telegram
                     -> Delivery Outcome -> Mark Delivered
```

Details that are there for a reason:

- **The configuration check comes before the claim.** An unconfigured install
  must never leave rows at `sending`, which is why the IF is the second node and
  not a filter further down.
- **`attempts` is incremented when the row is claimed, not when it is
  delivered.** A row that kills the workflow every time must still run out of
  attempts, or it blocks the queue forever.
- **Retries back off.** `NOTIFY_RETRY_BACKOFF_MINUTES` is multiplied by the
  attempt count. Without it the five minute schedule burns all five attempts in
  25 minutes and a Telegram outage shorter than lunch loses the day's
  notifications.
- **A dead run's claim is recoverable.** A row stuck at `sending` longer than
  `NOTIFY_STALE_CLAIM_MINUTES` becomes claimable again - the same idea as the 15
  minute window WF-04 uses on `agent_runs`.
- **The send continues on error.** A refused send arrives as data. If it threw,
  the claim would be abandoned and a credential-bearing error would be handed to
  WF-99.
- **Plain text, no `parse_mode`.** Markdown and HTML both need escaping, and
  these messages carry company names, error text and URLs written elsewhere. A
  missed escape either breaks the send or silently drops a line, and a dropped
  line in an alert is worse than an unstyled one.
- **No message id means not delivered.** Including an empty response. The point
  of the workflow is knowing whether the human was actually told.

### The bot token

It is **not** in `.env` for the sending path and it is **not** in the workflow
JSON. WF-10 uses the n8n Telegram node with a `telegramApi` credential, so n8n
holds the token encrypted and redacts it from execution data.

The alternative - an HTTP Request node to
`https://api.telegram.org/bot<token>/sendMessage` - writes the token into the
saved execution of every single run, which is exactly what `docs/security.md`
forbids. One credential in the n8n UI is a cheaper price.

Telegram also puts the token in its own error messages, so `Delivery Outcome`
redacts before anything is stored. **A bot token is `<digits>:<base64ish>`, and
the string that actually appears is `.../bot8123456789:AAH...` - there is no
word boundary between the `t` of `bot` and the first digit, so a `\b`-anchored
pattern matches nothing and the whole token lands in the database.** That was a
live bug, caught by a redaction test rather than by reading the code, which is
the same way the equivalent bug in WF-99 was found.

## When Telegram is not configured

Nothing breaks and nothing is lost. Notifications accumulate:

```sql
SELECT kind, priority, occurrences, first_seen_at, title
FROM v_pending_notifications;
```

That query is the substitute for the Telegram channel, and it is worth running
before turning delivery on for the first time - otherwise the first pass
delivers the entire backlog at once.

## Muting something

There is no command for this yet. A notification that is noise and should stay
quiet:

```sql
UPDATE notifications SET status = 'suppressed' WHERE dedup_key = '...';
```

It keeps counting occurrences and never re-opens on its own.

## What is not built

- **Commands.** `/approve`, `/reject`, `/status`, `/leads` and the rest of
  `docs/telegram.md` need a Telegram Trigger and the chat id check that goes
  with it. Until then the draft message says so rather than printing a command
  that does nothing.
- **A verified successful send.** Every branch of WF-10 has been executed
  against the live stack except the one that requires a real bot token: the
  unconfigured branch, the claim, the formatting, a failed delivery, the
  redaction and the retry backoff all ran. The success path has been tested
  against a synthetic Telegram response only.
- **Batching.** `draft_ready` is marked `batched` in the priority column but
  WF-10 still sends one message per row. Grouping them is the next thing to do
  if the approval queue ever gets long.
