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

**v0.2.0: all four tiers are verified end to end on real hardware.** That means the free
(SmolLM3-3B), Pro/Team (Phi-4-mini-instruct) and Enterprise (Qwen3-4B / Qwen3-8B) profiles, in
English and in Bahasa Indonesia. See `docs/TIERS.md` for the measured timings and the raw output.
RuleHawk is the first product with the Explain button in its dashboard. The rest of the
Hexward line is being wired in through the generic `hexward.explain_finding` feature.

## What this is not

- **Not a new product sold on its own.** It is infrastructure a licensed pilot product may
  turn on.
- **Not a change to how findings are produced.** RuleHawk's rule analyser and AuditLight's
  Change Report logic are completely unchanged; this sidecar only narrates their output.
- **Not a chat interface to your infrastructure.** It answers exactly two narrow, pre-defined
  questions (see below) — it does not take arbitrary questions, and it is not meant to.
- **Not a remediation tool.** It explains why a finding matters; it never drafts a fix.

## What it does

1. **RuleHawk — "Explain this finding."** One shadowed/permissive rule finding in, a
   plain-language explanation and a checklist of what to verify out. No drafted rule change.
2. **AuditLight / Posture Report — "Why did this finding disappear?"** One finding's coverage
   status in (`fixed` / `no_longer_detected` / `check_failed` / `target_skipped` — a
   classification the product already made), a plain-language explanation of what that
   actually means out. This exists specifically so "no longer detected" never gets misread as
   "fixed".
3. **Any product on the shared finding contract — "Explain this finding" (generic).** One
   finding in the shared `core.Finding` shape (CertLight, Attack Surface Monitor, Decoy,
   Patchlight, Loglight, DmarcWatch, TenantWatch, Posture Report), sanitised by
   `aiclient.NewFindingPacket`, and a plain-language explanation plus a verification checklist
   out. The product's own remediation text may be restated, never replaced.

Narration language is English or Bahasa Indonesia (`Language: "en" | "id"`).

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
docker build -t hexward/hexward-ai:0.2.4 -f docker/Dockerfile .
docker compose -f docker-compose.ai.yml up   # downloads the free-tier model on first start
curl http://127.0.0.1:8435/health
```

Full instructions, including a fully offline path with your own pre-downloaded model, are in
`docs/INSTALL.md`.

## Model tiers

| Profile | Edition | Model | Licence | Where it runs |
|---|---|---|---|---|
| `lab` | GitHub free | SmolLM3-3B | Apache-2.0 | Same host as the product, loopback only |
| `smb` | Whop Pro / Team | Phi-4-mini-instruct | MIT | Same host, or one dedicated AI host with an API key |
| `enterprise-4b` / `enterprise-8b` | Enterprise | Qwen3-4B / Qwen3-8B | Apache-2.0 | Dedicated AI host |
| BYO | Enterprise | Your OpenAI-compatible endpoint | yours | Your infrastructure |

Every profile pins its source commit, file size and SHA-256 (`profiles/*.env`), and
`scripts/fetch-model.sh <profile>` refuses any file that does not match both. Full details,
the dedicated-host setup and BYO notes are in `docs/TIERS.md`.

The calling product's own licence decides where it may send findings. The free edition talks
only to a loopback sidecar. Pro/Team and Enterprise may also use a remote AI host or a BYO
endpoint. This uses the existing Ed25519 licence tiers, so no new licensing system is needed.

## Server requirements

Approximate, CPU-only, additional to the product's own footprint:

| Tier model | RAM | Notes |
|---|---|---|
| SmolLM3-3B (lab) | +2-3 GB | Fine on a modest lab VM |
| Phi-4-mini-instruct (SMB) | +4 GB | +2 vCPU recommended |
| Qwen3 4B/8B (Enterprise) | +6-12 GB | Larger context, slower per-request on CPU |

The RAM figures above are approximations. Response times *were* measured, on a CPU-only VM,
and are published with the raw outputs in `docs/TIERS.md`. On that VM one explanation took
13–27 s for 3–4B models and about 50 s for Qwen3-8B.

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
- `NewFindingPacket` / `SanitizeEvidence`: builds the generic packet and drops secret-like
  evidence keys (password, token, secret, private, credential, cookie, session, signature and
  similar) at every nesting level. It also caps strings, lists, key count and nesting depth.
- `NormalizeLanguage`, plus an explicit language instruction at the end of both the system
  prompt and the user turn. Small models ignore a bare `"language"` field. This was measured,
  and it is why the instruction is there.
- `WithAPIKey` for a dedicated AI host or a BYO endpoint. `WithDisableThinking` for Qwen3.

Tested with `go test -race ./...` against an `httptest` mock server (no live model needed) —
see `internal/aiclient/client_test.go` for the full list of covered cases (happy path,
unreachable sidecar, 5xx retry exhaustion, non-retried 4xx, malformed JSON at both the
transport and model-content layers, context cancellation, and evidence-packet validation).

## Examples

`examples/explain-finding/` (generic, any tier: `-url`, `-lang id`, `-key-file`,
`-no-thinking`), `examples/rulehawk-explain-finding/` and `examples/auditlight-why-disappeared/`
are minimal, runnable programs showing exactly how a product calls `internal/aiclient`. Run
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
  `go test -race ./...` green (11 test functions, including subtests).
- `docker/Dockerfile` builds successfully on the team's own Ubuntu 24.04 DevNet VM, on top of
  the real, published `ghcr.io/ggml-org/llama.cpp:server` image (pinned by digest), **and the
  resulting container was actually run, loaded a real 1.9 GB model (checksum-verified against
  Hugging Face's own published `sha256`), answered `/health` with 200, and returned a real,
  grammar-valid response to a real chat-completions request** — see "What was verified end to
  end" below.
- `docker/grammar/response.gbnf` parses successfully against the real llama.cpp grammar parser
  (this took two real fixes to get right — see below) and its constrained output was observed
  matching the required schema on a live model, not just inspected for syntax.
- `docker-compose.ai.yml`: the `--hf-repo`/`--hf-file` values point at the exact Hugging Face
  repo and file this session downloaded and ran (`ggml-org/SmolLM3-3B-GGUF`,
  `SmolLM3-Q4_K_M.gguf`), not merely a plausible-looking name.

## What was verified end to end (with real evidence)

This session downloaded the free-tier model and ran it for real, twice — once with a raw
`curl` request, once through the actual `internal/aiclient` Go client — both against the image
this repo builds, on the team's own DevNet VM:

```
curl http://127.0.0.1:8436/v1/chat/completions ...
HTTPCODE:200
{"choices":[{"finish_reason":"stop","message":{"content":
  "{\"explanation\": \"...\", \"what_to_verify\": [...], \"disclaimer\": \"...\"}"
}}], "usage":{"completion_tokens":88,"prompt_tokens":103}, ...}
```

and, separately, `go run ./examples/auditlight-why-disappeared -sidecar http://127.0.0.1:8437`
against the same live model returned a real explanation and the exact canonical disclaimer,
client-enforced.

Two real bugs surfaced by this and were fixed in the same session, not just noted:

1. **The Dockerfile's `WORKDIR` broke the base image.** `ghcr.io/ggml-org/llama.cpp:server`'s
   `llama-server` binary resolves its own shared libraries via a CWD-relative path, not
   `$ORIGIN` — setting `WORKDIR` to anything other than `/app` made the container exit
   immediately with `error while loading shared libraries: libllama-server-impl.so`. Fixed by
   keeping `WORKDIR /app`.
2. **The GBNF grammar failed to parse.** llama.cpp's grammar parser only allows a rule
   definition to span multiple lines inside an explicit `(...)` group — my `root` rule split a
   bare top-level sequence across lines with no enclosing group, which fails with `expecting
   name at ...`. Fixed by wrapping the sequence in one group, matching how every multi-line
   rule in llama.cpp's own sample grammars is written.
3. **`internal/aiclient` sent no `max_tokens`.** On this VM's CPU, SmolLM3-3B generated at
   roughly 1 token/second under the grammar; an uncapped response ran past a 150s client
   timeout even though the grammar guarantees it eventually stops. Fixed by adding a
   `defaultMaxTokens` (512) and a `WithMaxTokens` override — covered by two new regression
   tests in `internal/aiclient/client_test.go`.

All three were found by actually running the thing, not by inspection — which is the reason
this session budgeted the ~2 GB download instead of stopping at "the code compiles."

## What is not done yet

Named honestly so the next session (or the next engineer) does not have to rediscover it:

1. **Product wiring is in progress.** RuleHawk's dashboard has the Explain button on `main`.
   Each other product gets it in its own release. The product's README and CHANGELOG say when
   it has shipped.
2. **The full CI grounding gate from spec §10 is not implemented.** CI currently builds the
   Docker image (`docker build`) as a compile-time check; it does not yet bring up a model and
   assert (a) grammar-valid JSON, (b) no invented token, (c) no panic when the sidecar is
   killed mid-request. This needs a decision about where a ~2 GB model download and ~90s of
   CPU inference fits in CI budget before it can be built responsibly.
3. **Bahasa Indonesia on the free tier is experimental.** In the tier matrix SmolLM3-3B
   produced Indonesian with spelling errors, and once it mentioned a time zone that was not in
   the evidence. Use English on the `lab` profile, or use `smb` or Enterprise for Indonesian.
   Responses take seconds to tens of seconds on CPU, so products always show a visible
   "explaining…" state.
4. **The naive grounding check (spec §10.b: "no token outside the evidence packet appears in
   the response") has not been automated.** The one real response captured above was read by a
   human, not checked by a script, for whether it stayed grounded — building that check is part
   of the CI gate work in point 2.

## Licensing

Apache-2.0 (see `LICENSE`) — this repository has one edition, always free, the same as every
other Hexward GitHub repo's free build. Whether a *pilot product* offers AI Assist to a given
customer is controlled entirely by that product's own license (the `ai_assist` flag), not by
anything here.

---

Nizar Tuanku — Cybersecurity. · github.com/nizartuanku/hexward-ai
