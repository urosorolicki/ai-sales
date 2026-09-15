# Ollama

The local model. It runs **natively on the host, not in a container.**

## Why not in Docker

Docker Desktop on macOS runs containers inside a Linux VM with no Metal
passthrough. An Ollama container on this machine gets no GPU and runs entirely on
the CPU - `ollama ps` reports `100% CPU` - on a Mac Mini whose M4 Pro has a
16-core GPU and 24 GB of unified memory sitting idle.

The difference is not marginal. The same triage call took 17 seconds in the
container and a few seconds natively.

Unified memory is the reason Apple Silicon is good at this: the GPU can address
almost all of system RAM, so model size is limited by how much RAM you are
willing to give it rather than by a fixed amount of VRAM.

## How n8n reaches it

`docker-compose.yml` maps the hostname `ollama` to the host gateway:

```yaml
extra_hosts:
  - "ollama:host-gateway"
```

So `http://ollama:11434` still resolves from inside n8n, and every URL, stored
credential and default that already said `http://ollama:11434` keeps working.
Nothing had to be re-pointed.

## Running it

```bash
brew install ollama
brew services start ollama      # survives a reboot
ollama serve                    # or run it in the foreground
```

`make pull-model` pulls the model named in `OLLAMA_MODEL`. `make health` checks
Ollama twice: on the host, and from inside n8n - the second is the path that
actually matters, and it is the one that breaks silently if the `extra_hosts`
entry is lost.

## Exposure

`ollama serve` binds `*:11434`, which means every interface, not just loopback.
That is what lets the container reach it, and it also means anything on the local
network can reach it. On a home network behind NAT that is usually acceptable;
on an untrusted network it is not. Ollama has no authentication of any kind.

If that matters, bind it to the Docker bridge address instead of the wildcard:

```bash
OLLAMA_HOST=192.168.65.254:11434 ollama serve
```

Do not expose port 11434 through Caddy. See `docs/security.md`.

## Memory

The models and Docker Desktop compete for the same 24 GB.

| | |
|---|---|
| Docker Desktop allocation | set in Docker Desktop > Settings > Resources |
| Stack actually needs | roughly 6-8 GB for Postgres, Redis, n8n and Caddy |
| `qwen3.5:9b` | 6.1 GB |
| `qwen3.6:27b` | 16.2 GB |

A 16 GB Docker allocation leaves no room for a 27B model and pushes the machine
into swap. Lowering it to 8 GB is the difference between the 27B model being
usable and not.

Check before loading a large model:

```bash
vm_stat | head -4
sysctl -n vm.swapusage
```

## Which model

`OLLAMA_MODEL` in `.env`. Currently `llama3.1:8b`.

Two things to know about the alternatives already on this machine:

- **`qwen3.5:9b` and `qwen3.6:27b` are reasoning models.** The response carries
  both `content` and `thinking`, and thinking tokens count against
  `num_predict`. A budget sized for the answer alone comes back with an empty
  `content`. Send `"think": false` on `/api/chat`, or raise the budget
  substantially. The n8n Ollama Chat Model node does not expose `think`, which is
  why WF-00 uses a non-reasoning model.
- **Structured outputs work on `/v1/chat/completions`, not on `/api/chat`.** On
  the installed version `/api/chat` silently ignores `format`: a schema requiring
  two keys produced neither, an enum of three colours produced a fourth, and the
  research schema came back with the array fields and none of the scalar ones,
  across two different models. The OpenAI-compatible endpoint with

  ```json
  "response_format": {"type": "json_schema",
                      "json_schema": {"name": "x", "strict": true, "schema": {...}}}
  ```

  is enforced: exactly the required keys, no extras. It also puts a reasoning
  model's thinking in a separate `reasoning` field, so `content` is clean JSON
  without needing `think: false`. WF-02 uses that endpoint.

- **`/v1/chat/completions` takes no `options`, so `num_ctx` cannot be set per
  request.** The context window comes from the model, and the default 4096 is not
  enough for a schema plus a page of material - the object is cut off mid-key and
  `finish_reason` comes back `length`. Use a model built with a larger window
  (`ollama create` from a Modelfile with `PARAMETER num_ctx`), which is what
  `qwen9-64k` and `qwen27-32k` are.

- **The schema constrains keys and types, not enums or numeric bounds.** In a
  real scoring run the model returned `total_score: 109` against a schema maximum
  of 100, and put a score band in a field whose enum has four offer names in it.
  Treat `required` and `type` as enforced and everything else as advisory.

- **Validate the response anyway.** Enforcement fixes the shape, not the
  judgement: the schema will happily accept `confidence: 0.95` on four lines of
  evidence.

- **`reasoning_effort: "none"` turns thinking off; nothing else does.** On
  `/v1/chat/completions`, `reasoning_effort: "low"` still produced 41000
  characters of reasoning and `chat_template_kwargs: {enable_thinking: false}`
  produced 47000 and then ran out of budget. `"none"` produced zero. Reasoning
  tokens are **not** counted in `usage.completion_tokens` but they do consume
  `max_tokens`, so a request sized for the answer alone comes back
  `finish_reason: length` with empty content and a usage figure that makes it
  look like nothing happened.

  Whether to turn it off is per task, not global: scoring is 13 seconds without
  it against 218 with, and the scores are no worse. Research without it dropped
  six required keys.

## What the local model is used for

| Where | Job | Why local |
|---|---|---|
| WF-00 | Pipeline smoke test | It only has to prove the wiring works |
| WF-02 triage | Yes/no: is there anything here worth the bigger model | High volume, structurally simple, and a wrong answer is caught by being biased towards yes |
| WF-02 research | The full evidence file | Free, and good enough at extraction - see below |

### Measured

| Model | Job | Time |
|---|---|---|
| `llama3.1:8b` | triage | 5-9s |
| `qwen9-64k` | research (reasoning on) | ~170s |
| `qwen9-64k` | scoring (reasoning off) | ~13s |
| `qwen27-32k` | research | ~550s, and it spills to the CPU at 32k context |

The 27B model is better calibrated - `confidence` 0.6 against the 9B's 0.92 on
the same material - and gives more specific `unknown` entries. It is also three
times slower and does not fit in memory alongside a 16 GB Docker allocation.
`qwen9-64k` is the working default.

| WF-04 scoring | Apply the rubric | Free, and the rubric's checkable rules are enforced in code rather than trusted - see `docs/lead-scoring.md` |

Outreach and conversation still assume an external model. That is where the
local model's uncalibrated judgement would show up in something a human reads.
