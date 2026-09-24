# hexward-ai

**A local, optional AI narration sidecar for the Hexward product line — it explains findings your product already found, and it never invents one.**

Hexward products (RuleHawk, AuditLight, and the rest of the line) each run their own
deterministic Go engine to find things — a shadowed firewall rule, an assessment finding that
vanished between two runs. That engine is, and stays, the only source of truth: what it finds,
and how severe it is, never changes.

What a deterministic engine is bad at is prose. "rule.shadowed, rule_index 14, shadows 8" is
exactly correct and not obviously useful to someone new to firewall auditing. `hexward-ai` is
a small local language model, running in its own container, whose only job is turning a
finding a product already produced into a sentence a person can act on — nothing more. See
`docs/CONCEPTS.md` for the full reasoning, including the two independent grounding mechanisms
this sidecar uses and why one alone is not enough.

## Status

**Early scaffolding — not yet wired into any product's UI, and not yet run against a live
model in this session.** See "What is done" and "What is not done yet" below before deciding
whether to depend on this. There is no tagged release; everything here is built from `main`.

## What this is not

- **Not a new product sold on its own.** It is infrastructure a licensed pilot product may
  turn on.
- **Not a change to how findings are produced.** RuleHawk's rule analyser and AuditLight's
  Change Report logic are completely unchanged; this sidecar only narrates their output.
- **Not a chat interface to your infrastructure.** It answers exactly two narrow, pre-defined
  questions (see below) — it does not take arbitrary questions, and it is not meant to.
- **Not a remediation tool.** It explains why a finding matters; it never drafts a fix.

## Phase 1 pilot: the only two things it does

1. **RuleHawk — "Explain this finding."** One shadowed/permissive rule finding in, a
   plain-language explanation and a checklist of what to verify out. No drafted rule change.
2. **AuditLight / Posture Report — "Why did this finding disappear?"** One finding's coverage
   status in (`fixed` / `no_longer_detected` / `check_failed` / `target_skipped` — a
   classification the product already made), a plain-language explanation of what that
   actually means out. This exists specifically so "no longer detected" never gets misread as
   "fixed".

## Architecture

```
Hexward product (Go, single binary)
  └─ finding already produced by its own deterministic engine (unchanged)
  └─ internal/aiclient (copied into that product's repo — see "Why copied, not imported")
       └─ POSTs a small evidence packet to hexward-ai over TCP 127.0.0.1:8435 (default)
       └─ receives grammar-constrained JSON back
       └─ renders it, labelled "AI-generated summary — verify against raw findings"

hexward-ai (this repo, separate Docker image)
  └─ llama.cpp server (upstream, ghcr.io/ggml-org/llama.cpp:server — not forked)
  └─ Hexward prompt templates, one per pilot feature (docker/prompts/)
  └─ GBNF grammar enforcing valid JSON output (docker/grammar/response.gbnf)
  └─ model NOT bundled in the image — mounted or downloaded separately, verified by checksum
```

If `hexward-ai` is absent, unreachable, or times out, the product functions exactly as it does
today — no AI section rendered, no crash. This mirrors the existing "invalid license key →
friendly notice, no crash" guard pattern already used across the line.

## Why copied, not imported

There is no shared "Hexward Core" Go module anywhere in the line — every product, verified
directly against all 13 repos, is its own standalone module. `internal/aiclient` is written
once, here, and copied verbatim into each pilot product's own repo, the same pattern already
used for Ed25519 license validation (RuleHawk's and AuditLight's `license.go` are two
independent implementations that only agree on a wire format). See `docs/CONCEPTS.md` for the
full explanation.

## Quick start

```bash
git clone https://github.com/nizartuanku/hexward-ai.git
cd hexward-ai
docker build -t hexward/hexward-ai:0.1.0 -f docker/Dockerfile .
docker compose -f docker-compose.ai.yml up   # downloads the free-tier model on first start
curl http://127.0.0.1:8435/health
```

Full instructions, including a fully offline path with your own pre-downloaded model, are in
`docs/INSTALL.md`.

## Model tiers

| Tier | Model | License | Notes |
|---|---|---|---|
| GitHub lab (free) | SmolLM3-3B | Apache-2.0 | Lightest download, CPU-only demo |
| SMB — Pro/Team | Phi-4-mini-instruct | MIT | CPU-capable, native multilingual (EN/ID), 128K context |
| Enterprise | Qwen3 4B/8B, or BYO-endpoint | Apache-2.0 | Stronger reasoning; BYO avoids Hexward distributing large weights |

Which tier is available is decided by the calling product's own license (a new `ai_assist`
flag on the existing Ed25519 payload — no new licensing system), not by anything in this repo.

## Server requirements

Approximate, CPU-only, additional to the product's own footprint:

| Tier model | RAM | Notes |
|---|---|---|
| SmolLM3-3B (lab) | +2-3 GB | Fine on a modest lab VM |
| Phi-4-mini-instruct (SMB) | +4 GB | +2 vCPU recommended |
| Qwen3 4B/8B (Enterprise) | +6-12 GB | Larger context, slower per-request on CPU |

These are vendor/quantization-level approximations, not measured on Hexward's own hardware —
unlike the RSS figures Hexward publishes for its Go binaries, no one has benchmarked these
models end to end in this repo yet (see "What is not done yet").

## `internal/aiclient`

The Go client every pilot product copies into its own repo:

- `Client.Explain(ctx, EvidencePacket) (*Explanation, error)` — the single entry point for
  both pilot features.
- Typed request/response structs (`EvidencePacket`, `RuleHawkFinding`,
  `AuditLightDisappearance`, `Explanation`) — no raw `map[string]interface{}`, no free-form
  strings.
- Configurable timeout and bounded retries (`WithTimeout`, `WithMaxRetries`,
  `WithRetryBackoff`) — retries only on transport errors and HTTP 5xx, never on 4xx or a
  malformed response, because retrying an identical bad request produces an identical bad
  response.
- `ErrUnavailable` / `IsUnavailable` for the "sidecar is absent, render nothing" case spec §3
  requires; `ErrInvalidRequest` and `ErrInvalidResponse` are distinct sentinels for the two
  different ways a *reachable* sidecar can still fail.
- The `disclaimer` field returned to callers is always the canonical sentence, overwritten by
  the client itself — never taken on trust from the model.

Tested with `go test -race ./...` against an `httptest` mock server (no live model needed) —
see `internal/aiclient/client_test.go` for the full list of covered cases (happy path,
unreachable sidecar, 5xx retry exhaustion, non-retried 4xx, malformed JSON at both the
transport and model-content layers, context cancellation, and evidence-packet validation).

## Examples

`examples/rulehawk-explain-finding/` and `examples/auditlight-why-disappeared/` are minimal,
runnable programs showing exactly how each pilot product would call `internal/aiclient`. Run
either one against a live sidecar with `go run ./examples/<name>`.

## Security & grounding rules (spec §7)

- The prompt instructs the model to use only the evidence packet's fields; the GBNF grammar
  separately constrains output shape. Neither alone is sufficient — see `docs/CONCEPTS.md`.
- Every response's disclaimer is enforced client-side, not left to the model.
- `hexward-ai` never receives credentials, raw config files, or full database dumps — only the
  minimal evidence packet a product chooses to send.
- Zero outbound network calls from `hexward-ai` itself once serving requests — no cloud
  fallback, ever. (The one opt-in exception, at container *startup* rather than at request
  time, is the lab/dev Hugging Face model download described in `docs/INSTALL.md` — production
  and any offline deployment should mount a pre-downloaded file instead and never trigger it.)

## What is done (with evidence, not claims)

- `internal/aiclient`: real Go package, builds, `gofmt -l .` empty, `go vet ./...` clean,
  `go test -race ./...` green (9 test functions, including subtests).
- `docker/Dockerfile` builds successfully on the team's own Ubuntu 24.04 DevNet VM, on top of
  the real, published `ghcr.io/ggml-org/llama.cpp:server` image (pinned by digest).
- `docker/grammar/response.gbnf`, `docker/prompts/*.tmpl`, `docker-compose.ai.yml`: written
  against real, verified llama.cpp server flags (`--grammar-file`, `--hf-repo`, `--hf-file`,
  `--host`, `--port`) and a real, verified Hugging Face GGUF repo (`ggml-org/SmolLM3-3B-GGUF`,
  file `SmolLM3-Q4_K_M.gguf`).

## What is not done yet

Named honestly so the next session (or the next engineer) does not have to rediscover it:

1. **Live inference has not been exercised end to end.** Downloading the ~2 GB SmolLM3-3B
   weights and sending a real evidence packet through a real running model was out of this
   session's time/network budget. Everything that does not require the weights themselves —
   the client, the grammar file's syntax, the Dockerfile build — has been built and tested;
   whether the *served* JSON actually satisfies the grammar and stays grounded in practice has
   not been verified against a live model. **This is the natural next job.**
2. **Not wired into RuleHawk's or AuditLight's real UI.** `examples/` shows the calling pattern
   with a hand-built sample finding; neither product's dashboard calls `internal/aiclient` yet.
3. **The full CI grounding gate from spec §10 is not implemented.** CI currently builds the
   Docker image (`docker build`) as a compile-time check; it does not yet bring up a model and
   assert (a) grammar-valid JSON, (b) no invented token, (c) no panic when the sidecar is
   killed mid-request. This needs a decision about where a ~2 GB model download fits in CI
   budget before it can be built responsibly.
4. **Phi-4-mini-instruct and Qwen3 have not been downloaded, run, or benchmarked.** Only the
   free-tier SmolLM3-3B path has real (address-verified) source references; the SMB and
   Enterprise rows in the model table above are the spec's stated choice, not something this
   session measured.

## Licensing

Apache-2.0 (see `LICENSE`) — this repository has one edition, always free, the same as every
other Hexward GitHub repo's free build. Whether a *pilot product* offers AI Assist to a given
customer is controlled entirely by that product's own license (the `ai_assist` flag), not by
anything here.

---

Nizar Tuanku — Cybersecurity. · github.com/nizartuanku/hexward-ai
