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
- **Structured outputs behave differently between versions.** Passing a JSON
  Schema as `format` constrained output to every required key on 0.5.4, but not
  on 0.31.1 with the research schema - the model returned the array fields and
  omitted the scalar ones. Do not assume `format` guarantees a schema; validate
  the response regardless. WF-02 does.

## What the local model is used for

| Where | Job | Why local |
|---|---|---|
| WF-00 | Pipeline smoke test | It only has to prove the wiring works |
| WF-02 triage | Yes/no: is there anything here worth a paid call | High volume, structurally simple, and a wrong answer is caught by being biased towards yes |

Research, scoring, outreach and conversation use the external model. That is a
cost decision, not a permanent one - see `docs/company-research.md` for what the
local model actually produced when asked to do the research itself.
