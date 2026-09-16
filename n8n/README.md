# n8n

n8n is the orchestrator. The workflow specifications live in
`docs/workflows.md`; this file is about running and versioning them.

## Access

`http://localhost:5678`, behind basic auth (`N8N_BASIC_AUTH_USER` /
`N8N_BASIC_AUTH_PASSWORD` from `.env`), or through Caddy once a domain exists.

## Where state lives

| What | Where |
|---|---|
| Workflows, executions, credentials | PostgreSQL, schema `n8n` |
| Encryption key for credentials | `N8N_ENCRYPTION_KEY` in `.env` |
| Instance config, custom nodes | Docker volume `n8n_data` |
| Queue state | Redis |

`make backup` captures the first, because it dumps the whole database. It does
not capture the second, on purpose - see `docs/security.md`.

## Versioning workflows

`n8n/workflows/` holds exported JSON, committed to git. Exports contain node
definitions and parameters but **not credential values**, only credential
references by name and id. That is what makes them safe to commit, and it is
worth verifying after the first export rather than assuming.

Import on a new machine, or after editing the JSON by hand:

```bash
docker exec aisales-n8n n8n import:workflow --separate --input=/workflows
```

`--separate` is required even for a directory of single-object files. Without it
the import fails with `workflows.map is not a function`.

Export everything. `./n8n/workflows` is mounted **read-only** at `/workflows`, so
an export cannot write there and has to come back out through `docker cp`:

```bash
docker exec aisales-n8n n8n export:workflow --all --pretty --output=/tmp/export
docker cp aisales-n8n:/tmp/export/. ./n8n/workflows/
docker exec -u root aisales-n8n rm -rf /tmp/export
```

Read-only is the right way round: the JSON in git is the source of truth and the
n8n database is the copy, so a change made in the UI has to be exported
deliberately rather than by accident.

Credentials are re-entered by hand on a new machine, or restored with the
database and the matching encryption key.

Validate before importing:

```bash
python3 infra/scripts/validate-workflows.py     # also part of make validate
```

It reads the JSON only and catches the failures n8n does not report until a
workflow runs: a connection pointing at a renamed node, a node left unreachable,
a Postgres node with a `$1` placeholder and nothing to fill it, an `errorWorkflow`
naming a workflow that is not here, and anything that looks like a credential in
the file.

Run `make secrets-scan` after every export. It is cheap, and an export that
picked something up is exactly the kind of thing that is noticed six months
later in a public repository.

## Node conventions

**Database access** through the PostgreSQL node using a stored credential, never
a connection string in a node parameter.

**HTTP requests** with an explicit timeout. A default-timeout request to a slow
careers page will hold a workflow open for minutes.

**Every workflow sets WF-99 as its error workflow.** Settings > Error Workflow.
A workflow without one fails silently.

**Claim work with `FOR UPDATE SKIP LOCKED`:**

```sql
UPDATE companies SET status = 'researching'
WHERE id IN (
    SELECT id FROM companies
    WHERE status = 'new'
    ORDER BY created_at
    LIMIT 10
    FOR UPDATE SKIP LOCKED
)
RETURNING *;
```

Two overlapping runs then process different rows instead of the same ones.

**Agent runs are bracketed.** Insert `agent_runs` with `status = 'running'`
before the model call; update it to a terminal status after. A row left at
`running` is how WF-101 detects a workflow that died mid-execution.

**Idempotency.** Re-running a workflow must not duplicate a row or resend a
message. The unique indexes on `signals`, `outreach` and `messages` are there to
make that a database guarantee rather than a workflow discipline.

## Running one by hand

A workflow with a Manual Trigger runs from the CLI:

```bash
docker exec -e N8N_RUNNERS_ENABLED=false aisales-n8n n8n execute --id=wf00PipelineTest
```

`N8N_RUNNERS_ENABLED=false` is not optional. The task runner registers with the
main process, and a separate CLI process has none, so the execution hangs
forever without it.

**A schedule-triggered workflow cannot be started this way** - `n8n execute`
answers "Missing node to start execution". Either click **Test workflow** in the
UI, or import a copy whose trigger is swapped for a Manual Trigger, run that by
id, and delete it afterwards:

```sql
DELETE FROM n8n.execution_entity WHERE "workflowId" LIKE 'tmpExec%';
DELETE FROM n8n.workflow_entity  WHERE id LIKE 'tmpExec%';
```

Import is not execution. A workflow that imported cleanly has proved nothing
except that its JSON parses.

## Execution data

Executions are pruned after 14 days (`EXECUTIONS_DATA_MAX_AGE=336` hours). Both
successes and failures are saved: a successful run that produced a bad draft is
usually more informative than a failed one.

This is the main source of database growth. If the database grows faster than
expected, this setting is the first thing to look at.
