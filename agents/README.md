# Agents

An "agent" here is a prompt plus an input/output contract plus a place in the
pipeline. There is no agent runtime and no agent framework: n8n calls a model
with the prompt from `prompts/`, validates the response against the schema in
this directory, and writes the result to PostgreSQL.

That is deliberate. The orchestration problem this project has is scheduling,
retries and state - which n8n already solves - not agent autonomy.

| Agent | Prompt | Workflow | Model | Writes |
|---|---|---|---|---|
| research | `prompts/research.md` | WF-02 | `claude-sonnet-5` | `companies`, `signals` |
| scoring | `prompts/scoring.md` | WF-04 | external LLM | `companies.*_score`, `leads` |
| outreach | `prompts/outreach.md` | WF-05 | external LLM | `outreach` (draft) |
| classifier | `prompts/classifier.md` | WF-08 | Ollama, escalating to external LLM | `messages.classification`, `suppression_list` |
| conversation | `prompts/conversation.md` | WF-09 | external LLM | `messages`, `conversations` |

## Contract

Every agent directory contains:

- `README.md` - what it does, what it must never do, how it fails
- `schema.json` - JSON Schema for the output, used by n8n to reject malformed
  responses before they reach the database

## Rules that apply to all agents

1. **Every invocation writes an `agent_runs` row.** Insert with
   `status = 'running'` before the model call, update on completion. A run with
   no terminal status after 15 minutes is a hung workflow and WF-101 reports it.
2. **Validate before writing.** A response that does not match `schema.json` is
   an error, not something to coerce. Retry once, then fail the run.
3. **Raw output is stored.** `agent_runs.output` holds what the model actually
   returned, before any transformation. Without it, a bad outcome cannot be
   explained three weeks later.
4. **No agent sends anything.** Agents produce rows. WF-06 is the only workflow
   that talks to the outside world, and in Phase 1-7 it only does so for rows a
   human approved.
5. **Temperature stays low, where the model accepts one.** `LLM_TEMPERATURE=0.2`
   applies to Ollama. It does **not** apply to `claude-sonnet-5`, which rejects
   `temperature`, `top_p` and `top_k` with an HTTP 400 - WF-02 therefore sends no
   sampling parameters at all. These are extraction and judgement tasks;
   creativity here shows up as invented facts, and on the external model that is
   controlled by the prompt and by validation rather than by a sampling knob.
6. **Model choice is cost, not capability, until proven otherwise.** The
   classifier runs locally because it is high volume and structurally simple.
   Research and conversation use the external model because being wrong there
   is expensive.
