# Model tiers, profiles and BYO endpoints

hexward-ai serves one model at a time. Which model depends on the edition of the Hexward
product that calls it. Every tier uses the same client, the same grammar and the same grounding
rules. Only the weights and where the sidecar runs are different.

| Profile | Edition | Model (GGUF Q4_K_M) | Weights licence | Download | Where it runs |
|---|---|---|---|---|---|
| `lab` | GitHub free | SmolLM3-3B | Apache-2.0 | 1.9 GB | Same host as the product, loopback only |
| `smb` | Whop Pro / Team | Phi-4-mini-instruct | MIT | 2.5 GB | Same host, or one dedicated AI host serving several products (API key required) |
| `enterprise-4b` | Enterprise | Qwen3-4B | Apache-2.0 | 2.5 GB | Dedicated AI host |
| `enterprise-8b` | Enterprise | Qwen3-8B | Apache-2.0 | 5.0 GB | Dedicated AI host |
| BYO | Enterprise | Your own OpenAI-compatible endpoint | yours | — | Your infrastructure |

Each profile in `profiles/*.env` pins the Hugging Face repository, the exact commit, the file
name, its size in bytes and its SHA-256. `scripts/fetch-model.sh <profile>` downloads that exact
file, checks both the size and the hash, and deletes it if either one does not match.

**Where the weights come from.** SmolLM3 comes from `ggml-org`, and Qwen3 comes from Qwen's own
official GGUF repositories. Microsoft does not publish an official GGUF build of
Phi-4-mini-instruct. The `smb` profile therefore uses Unsloth's quantization of Microsoft's
MIT-licensed weights, pinned to one commit and verified by hash. If your policy requires
first-party artifacts only, convert the upstream `microsoft/Phi-4-mini-instruct` weights
yourself with llama.cpp's `convert_hf_to_gguf.py`. Then mount the result the same way.

## Run a tier

```sh
scripts/fetch-model.sh smb                      # once; the only network step
docker compose --env-file profiles/smb.env -f docker-compose.tier.yml up -d
curl -s http://127.0.0.1:8435/health
```

`docker-compose.tier.yml` never downloads anything. If the model file is missing, the container
stops with an error instead of reaching the internet. It runs read-only, drops all capabilities
and binds to `127.0.0.1` by default.

For Qwen3 profiles, call the sidecar with `aiclient.WithDisableThinking()`. The profile sets
`HEXWARD_AI_DISABLE_THINKING=1` as a reminder. Explaining one finding does not need Qwen3's
hidden reasoning pass, and on CPU that pass multiplies latency.

## One AI host for several products (Pro / Team, Enterprise)

```sh
mkdir -p secrets && openssl rand -hex 32 > secrets/ai_api_key
sudo chown 10435:10435 secrets/ai_api_key && sudo chmod 400 secrets/ai_api_key
docker compose --env-file profiles/smb.env \
  -f docker-compose.tier.yml -f docker-compose.remote.yml up -d
```

The remote overlay binds beyond loopback, and it refuses to start without a key of at least 24
characters (`HEXWARD_AI_REQUIRE_API_KEY=1`). llama.cpp then rejects any request that has no
matching `Authorization: Bearer` header with HTTP 401. `/health` stays open so health checks
work without the key. The traffic is plain HTTP. Keep the AI host on a management network, or
put a TLS reverse proxy in front of it.

The calling product uses the same client with `aiclient.WithAPIKey(key)`.

## Bring your own endpoint (Enterprise)

Any server that implements OpenAI-style `POST /v1/chat/completions` works as a BYO endpoint,
for example vLLM, Ollama or an internal LLM gateway. Point the product at its base URL and pass
the key with `WithAPIKey` if the endpoint needs one. Two things behave differently from the
Hexward sidecar:

- **Grammar.** Only llama.cpp enforces the `grammar` field. On other servers, output that is
  not the required JSON shape comes back as `ErrInvalidResponse`, and the product then shows
  nothing. It never shows malformed text. vLLM users can get the same guarantee from its own
  structured-output options.
- **Unknown fields.** `WithDisableThinking` sends `chat_template_kwargs`. vLLM and llama.cpp
  accept it. Some strict gateways reject unknown fields, so do not set it for those.

The evidence packet that leaves the product is the same in every tier. It holds one finding,
built with `aiclient.NewFindingPacket`. Secret-like keys (password, token, secret, private,
credential, cookie, session, signature, and similar) are removed. Strings, lists and nesting
depth are capped. No raw configs and no credentials are sent.

## Measured on real hardware

Measured on 24 Sep 2026 on the Hexward DevNet VM: CPU only, 8 threads per sidecar, four
sidecars running at the same time. Each request explained one CertLight-style certificate
finding, capped at 300 output tokens. Full raw output is in
`verification/2026-09-24-tier-matrix.txt`.

English is the supported language in this release. The Bahasa Indonesia column is a preview
measurement only; more languages will be added based on demand.

| Profile | English | Bahasa Indonesia | Notes |
|---|---|---|---|
| lab (SmolLM3-3B) | 22.1 s | 13.1 s | English is good. Indonesian is **experimental** on this tier: it had spelling errors, and it once added a time zone that was not in the evidence. |
| smb (Phi-4-mini) | 22.2 s | 15.0 s | Grounded in both languages. The Indonesian reads naturally. |
| enterprise-4b (Qwen3-4B) | 27.1 s | 25.0 s | Most complete checklist in this run. Strongest Indonesian. |
| enterprise-8b (Qwen3-8B) | 52.6 s | 49.3 s | Most careful wording. Needs a stronger host or a GPU for interactive use. |

Every response was grammar-valid JSON, and every response carried the canonical disclaimer. The
`private_key_path` field in the sample evidence was removed before sending, so no model saw it.
A request without the key was rejected with HTTP 401 by the `smb` sidecar, which had the remote
settings on.

These timings are for sidecars sharing one CPU. A dedicated host, or a GPU build of llama.cpp,
is much faster. Products show a visible "explaining…" state, and nothing in a product waits on
the AI.
