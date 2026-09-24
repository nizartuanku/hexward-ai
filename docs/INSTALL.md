# Installing hexward-ai

This repository has no tagged release yet (see README "Status" and CHANGELOG
"Unreleased") — there is no `releases/latest` asset to download. Everything
below is a source build, verified on the Hexward team's own Ubuntu 24.04
DevNet VM (Go 1.27, Docker 29.8) at the commit this file ships with.

## 1. Requirements

- Docker with Compose v2 (`docker compose`, not the old `docker-compose`)
- ~4 GB free disk for the free-tier model, more for SMB/Enterprise tiers (see table below)
- Outbound internet access **only if** you use the lab auto-download path in step 3 — a fully
  offline install is step 4

## 2. Clone and build the image

```bash
git clone https://github.com/nizartuanku/hexward-ai.git
cd hexward-ai
docker build -t hexward/hexward-ai:0.1.0 -f docker/Dockerfile .
```

The base image is `ghcr.io/ggml-org/llama.cpp:server`, the llama.cpp project's own published
server image — not a fork, not patched. `docker/Dockerfile` only adds Hexward's grammar,
prompt templates and entrypoint script on top of it.

## 3. Lab / dev: auto-download the free-tier model (needs internet, once)

```bash
docker compose -f docker-compose.ai.yml up
```

First start downloads `SmolLM3-Q4_K_M.gguf` (~2 GB, Apache-2.0) from
`ggml-org/SmolLM3-3B-GGUF` on Hugging Face into a named Docker volume, so later restarts do
not re-download it. llama.cpp verifies the download against the file's published hash before
loading it — the same discipline Hexward's own product releases apply to their own binaries.

Wait for a log line like `main: server is listening on http://0.0.0.0:8435`, then:

```bash
curl -s http://127.0.0.1:8435/health
```

**Verified in this session:** the ~1.9 GB `SmolLM3-Q4_K_M.gguf` was downloaded, its sha256
matched Hugging Face's own published hash exactly, the container loaded it, `/health` answered
200, and a real `/v1/chat/completions` request returned a real, grammar-valid response — see
the README's "What was verified end to end" for the exact evidence and two real bugs that
testing found and fixed (a `WORKDIR` issue and a grammar syntax error). Generation speed on
that VM's CPU was roughly 1 token/second — set expectations accordingly for CPU-only hosts.

## 4. Offline / production: mount a pre-downloaded model yourself

Do this for anything that must not reach the internet, and for the SMB/Enterprise tiers
(Hugging Face does not host Phi-4-mini-instruct or Qwen3 under the exact names above — see the
model table in `README.md` for where each tier's weights come from).

```bash
docker run -d \
  --name hexward-ai \
  -p 127.0.0.1:8435:8435 \
  -v /path/on/host/model.gguf:/models/model.gguf:ro \
  hexward/hexward-ai:0.1.0
```

Verify the checksum of whatever `.gguf` file you downloaded against the value the model's own
publisher provides **before** mounting it — hexward-ai does not re-verify a file that is
already on disk when the container starts; that check happens once, at download time, by you
or by your own provisioning pipeline.

## 5. Point a product at it

A pilot product (RuleHawk, AuditLight) talks to hexward-ai over
`internal/aiclient.DefaultBaseURL` (`http://127.0.0.1:8435`) by default. See
`examples/rulehawk-explain-finding` and `examples/auditlight-why-disappeared` in this repo for
a runnable, minimal caller. Wiring this into either product's real UI has not happened yet —
see the README.

## 6. Running the Go client's own tests

No model or Docker required for this part — the client is tested against an `httptest` mock
server, not a live model:

```bash
gofmt -l .          # must print nothing
go vet ./...        # must be clean
go test -race ./...
```

## Model tiers and where their weights come from

| Tier | Model | License | Source |
|---|---|---|---|
| GitHub lab (free) | SmolLM3-3B | Apache-2.0 | `ggml-org/SmolLM3-3B-GGUF` on Hugging Face (used by step 3 above) |
| SMB — Pro/Team | Phi-4-mini-instruct | MIT | Download and verify from Microsoft's published release; mount per step 4 |
| Enterprise | Qwen3 4B/8B, or BYO-endpoint | Apache-2.0 | Download and verify from Alibaba's published release, or point `internal/aiclient` at the customer's own OpenAI-compatible endpoint instead of this sidecar entirely |

## Troubleshooting

- **`hexward-ai: FATAL — no model available.`** — you skipped step 3 or 4. The container will
  not silently start without a model; it exits with this message so the failure is loud
  instead of a confusing timeout later.
- **Health check never turns healthy** — on CPU, first model load for a 3B model can take
  1-2 minutes; `docker-compose.ai.yml`'s healthcheck allows up to 600s (`start_period`) before
  failing. Check `docker logs hexward-ai-lab` for the actual llama.cpp startup log.
- **Port 8435 already in use** — nothing else in the Hexward line uses this port (registry
  runs 8422-8434); check for a leftover container from a previous run: `docker ps -a | grep hexward-ai`.
