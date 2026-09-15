# WF-00 Pipeline Test

The first workflow in this repository. It proves one thing:

```
n8n  ->  Ollama  ->  PostgreSQL
```

It is not lead discovery. There is no Apollo, no email, no Telegram, no
LinkedIn, no scraping and no outreach in it, and none of those belong in it. It
exists so that the next workflow starts from a foundation that is known to work
rather than a guess.

Artifact: `n8n/workflows/ai-sales-pipeline-test.json`
Prompt: `prompts/pipeline-test.md`

## What it does

| | |
|---|---|
| Trigger | Manual, from the n8n editor |
| Input | One hardcoded fictional company: Example SaaS / example.com / SaaS |
| Steps | Open an `agent_runs` row -> ask Ollama to analyse the company -> validate the JSON -> close the run |
| Output | Exactly one `agent_runs` row, `status = 'success'` or `'error'` |
| Guards | Validation failure and Ollama failure both close the run as `error` and fail the execution |
| Idempotency | The run id is a fixed UUID. Re-running updates that one row rather than adding another. |

### Nodes

```
Manual Trigger
  -> Test Company            (Edit Fields, hardcoded)
  -> Open Agent Run          (Postgres: INSERT ... status='running')
  -> Analyse Company         (Basic LLM Chain + Ollama Chat Model)
       |
       +-- ok ---> Validate Response  (Code)
       |             -> Valid JSON?   (IF)
       |                  +-- true --> Record Success  -> Pipeline Test Passed
       |                  +-- false -> Record Failure  -> Fail Execution
       |
       +-- error -> Build LLM Failure -> Record Failure -> Fail Execution
```

The run is **bracketed**, per `n8n/README.md`: the row is written with
`status = 'running'` before the model is called and moved to a terminal status
after. A row left at `running` is how WF-101 will later detect a workflow that
died mid-execution.

### What it deliberately does not do

**It does not repair malformed model output.** A markdown fence, a truncated
object, a missing key or a `confidence` of `7` all fail the run. Nothing is
stripped, coerced or defaulted. A fake success here would be worse than a
failure, because it would teach the pipeline that broken output is acceptable.

**It does not create a table.** It writes to `agent_runs` from
`postgres/migrations/0006_agent_runs.sql`. The schema is unchanged.

## Storage

Everything lands in one row of `agent_runs`:

| Column | Value |
|---|---|
| `id` | `a15a1e57-7e57-4000-8000-000000000001`, fixed |
| `agent_name` | `research` |
| `input` | The test company, as supplied to the model |
| `output` | `{ validated, warnings, analysis, raw_response }` |
| `status` | `success` or `error` |
| `error` | The validation errors, or the Ollama error. NULL on success. |
| `model` | `llama3.1:8b`, from `OLLAMA_MODEL` |
| `started_at` / `finished_at` / `duration_ms` | Set by the two Postgres nodes |

`agent_name` is `research` because `agent_runs` has a CHECK constraint that
allows only `research`, `scoring`, `outreach`, `classifier`, `conversation` and
`radar`. Adding a `test` value would mean a migration for a throwaway workflow,
so the run is tagged inside `input.test` instead. Delete the row when the test
has served its purpose:

```sql
DELETE FROM agent_runs WHERE id = 'a15a1e57-7e57-4000-8000-000000000001';
```

## Credentials

Two, both already stored in n8n. Neither has any secret in the workflow file -
the export carries only a credential name and id.

| Credential | Type | Used by | Needs |
|---|---|---|---|
| Postgres account | `postgres` | Open Agent Run, Record Success, Record Failure | Host `postgres`, port `5432`, database and user from `.env` (`POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) |
| Ollama account | `ollamaApi` | Ollama Chat Model | Base URL `http://ollama:11434` |

`postgres` is a Docker network name on the `backend` network. `ollama` is not a
container: `docker-compose.yml` maps that hostname to the host gateway, because
Ollama runs natively so that it can use the GPU. See `docs/ollama.md`. It is not
proxied by Caddy.

The model name is not hardcoded. Both the Test Company node and the Ollama Chat
Model node read `{{ $env.OLLAMA_MODEL }}`, which `docker-compose.yml` passes
into the n8n container, falling back to `llama3.1:8b`.

## Importing

The file is a single workflow object, which is the format n8n's own
`export:workflow` produces and what `--separate` expects:

```bash
docker exec aisales-n8n n8n import:workflow --separate --input=/workflows/
```

`./n8n/workflows` is mounted at `/workflows` in the container. Importing the
whole directory is the documented procedure in `n8n/README.md`; the workflow
carries a fixed id (`wf00PipelineTest`), so re-importing updates it in place
rather than creating a copy.

From the UI instead: **Workflows > Import from File**, then pick
`n8n/workflows/ai-sales-pipeline-test.json`.

After importing on a **new machine**, open each of the four credential-bearing
nodes and re-select the credential. Credential ids are per-instance, so the ids
in the file will not resolve.

## Running it

In the editor, open **AI Sales — Pipeline Test** and click **Test workflow**.

From the command line:

```bash
docker exec -e N8N_RUNNERS_ENABLED=false aisales-n8n n8n execute --id wf00PipelineTest
```

The `N8N_RUNNERS_ENABLED=false` override is required, and applies only to that
one CLI process - it changes nothing about the running server. The task runner
registers with the main n8n process, so a separate `n8n execute` process has no
runner to talk to and hangs indefinitely before reaching Ollama. Without the
override the command never returns and the `agent_runs` row is left at
`running`. From the UI this does not arise.

A cold `llama3.1:8b` on CPU takes a while to load. Once warm, a run is roughly
15 seconds end to end on a Mac Mini.

## What success looks like

Every node green, and the **Pipeline Test Passed** node emitting:

```json
{
  "test": "AI Sales — Pipeline Test",
  "result": "passed",
  "agent_run_id": "a15a1e57-7e57-4000-8000-000000000001",
  "agent_run_status": "success",
  "duration_ms": 15877,
  "company": "Example SaaS",
  "model": "llama3.1:8b",
  "recommended_service": "none",
  "confidence": 0.5,
  "validation_warnings": ""
}
```

`recommended_service` should be `none` and `confidence` should be low. The model
was given four lines about a fictional company; anything confident would mean
the prompt is not holding.

That block is a real run, not an example: `llama3.1:8b` returned the schema
exactly, with `technology` and `reasonable_inferences` empty and eight entries
in `unknown`.

## Verifying the result

```bash
docker exec aisales-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
SELECT status, model, duration_ms, error,
       output #>> '{analysis,recommended_service}' AS service,
       output #>> '{analysis,confidence}'          AS confidence
FROM agent_runs
WHERE id = 'a15a1e57-7e57-4000-8000-000000000001';"
```

The full model output, including the untouched raw text, is in `output`:

```sql
SELECT jsonb_pretty(output) FROM agent_runs
WHERE id = 'a15a1e57-7e57-4000-8000-000000000001';
```

## What failure looks like

The execution is red in **Executions**, the run row is `status = 'error'` with a
readable message in `error`, and `output` holds `failure_stage` plus the raw
response that failed. Nothing is silently swallowed and no fake success row is
written.

Two failure stages:

| `failure_stage` | Cause |
|---|---|
| `llm_call` | Ollama unreachable, model not pulled, generation failed |
| `validation` | Response was not JSON, not an object, missing a key, wrong type, or `confidence` outside 0-1 |

To exercise the validation path on purpose, set the Ollama Chat Model's **Output
Format** back to `Default` and add "wrap your answer in a markdown code block"
to the prompt. The run must fail, not self-correct.

## Error workflow

WF-99 is set, as `settings.errorWorkflow: "wf99ErrorHandler"`. If WF-00 fails
anywhere, WF-99 closes the `agent_runs` row it left at `running`. The
`Open Agent Run` node records `$execution.id` in `input.execution_id`, which is
the only thing linking the row to an n8n execution. See
`docs/error-handling.md`.
