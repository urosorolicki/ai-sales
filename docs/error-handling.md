# WF-99 Error Handler

Set as the error workflow on every other workflow. Without it, a failure is a
red row in the n8n execution list that nobody looks at, and an `agent_runs` row
stuck at `running` forever.

Artifact: `n8n/workflows/ai-sales-error-handler.json`

## What it does

| | |
|---|---|
| Trigger | n8n Error Trigger |
| Input | The failed execution: workflow, failed node, error, execution id |
| Output | Any `agent_runs` row that execution left at `running` is closed as `error`; a sanitised alert payload |
| Guards | Never retries the failed workflow. Never touches a run that already reached a terminal status. Credentials are redacted before anything is stored. |
| Failure | WF-99 has no error workflow of its own, on purpose - it must not be able to re-enter itself. |

```
Error Trigger -> Error Context (Code) -> Close Agent Runs (Postgres) -> Alert Payload
```

## How a run is correlated to an execution

`agent_runs` has no n8n execution column and does not need one. Workflows write
`$execution.id` into `agent_runs.input`:

```
input -> { "execution_id": "5", "workflow_id": "wf00PipelineTest", ... }
```

WF-99 matches on that, and only on rows still at `running`:

```sql
WHERE status = 'running'
  AND input ->> 'execution_id' = ($1::jsonb ->> 'execution_id')
```

**Any new workflow that writes `agent_runs` must record `execution_id` in
`input`, or WF-99 cannot close its runs.** This is the one thing to copy from
WF-00 when building WF-02.

Zero rows closed is a normal, common outcome: the workflow may have failed
before it opened a run, or it may not call a model at all. The query is wrapped
in an aggregate so it always returns one summary row rather than nothing.

## Redaction

`docs/security.md` says alert text must not contain credentials. The Error
Context node redacts before anything is stored or sent:

| Pattern | Becomes |
|---|---|
| `postgresql://user:pass@host` | `postgresql://user:***@host` |
| `password=`, `secret=`, `api_key=`, `token=` | `... =***` |
| `Bearer <token>`, `Basic <token>` | `Bearer ***` |
| `eyJ...` (JWT) | `***jwt***` |

Messages are truncated at 500 characters, and **the stack trace is dropped
entirely** - it is already in the n8n execution, and it is the most likely place
for a connection string to appear.

Order matters in that function, and there is a comment saying so. The scheme
rules must run before the generic `key=value` rule; if they do not, the generic
rule consumes the word `Bearer` as though it were the value and leaves the real
token in the message. That was a live bug during development, caught by a
redaction test, not by reading the code.

## Wiring it to a workflow

**Settings > Error Workflow > AI Sales — WF-99 Error Handler.** WF-00 already
has it, stored as `settings.errorWorkflow` in the exported JSON. WF-99 does not
need to be active; error workflows are invoked directly.

## Telegram

Not wired up. `TELEGRAM_ENABLED=false` and `TELEGRAM_BOT_TOKEN` is empty in
`.env`, so there is nothing to send to.

The **Alert Payload** node already builds the message and emits
`delivery: "not_configured"`. Turning it on is one Telegram node on the end of
that chain, reading `alert` and `execution_url`.

Two things are still missing and must not be forgotten when that happens:

- **Deduplication.** `docs/workflows.md` requires it, so that one broken
  schedule does not send 96 messages a day. Redis is the obvious place for a
  short-TTL key per workflow and error, and there is no Redis credential in n8n
  yet.
- **Alert on WF-99's own failure.** Nothing watches the watcher. WF-101 Agent
  Health is where that belongs.

## Verifying it

There is no way to test an error workflow from the n8n UI without causing a real
failure. Break something on purpose - stop the Ollama container, or point the
Postgres credential at a wrong port - run WF-00, then check:

```sql
SELECT status, error, finished_at FROM agent_runs
WHERE id = 'a15a1e57-7e57-4000-8000-000000000001';
```

The run must be `error` with a readable, credential-free message, and the WF-99
execution must appear in the execution list next to the failed one.
