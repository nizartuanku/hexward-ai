# Changelog

## Unreleased

- **Fixed: Docker healthcheck reported "unhealthy" even when the sidecar was serving requests normally.** `docker-compose.ai.yml` and `docker-compose.tier.yml` ran `wget -q -O- http://127.0.0.1:8435/health` as the healthcheck command, but the upstream `ghcr.io/ggml-org/llama.cpp:server` image this Dockerfile builds on does not include `wget` (confirmed with `docker exec ... which wget` — not found; `curl` is present). Every check failed with "executable file not found in $PATH", so `docker ps` / `docker compose ps` showed the container as unhealthy indefinitely regardless of whether the server was actually up. Both compose files now use `curl -sf http://127.0.0.1:8435/health`, which is present in the base image. Verified live: container recreated from the fixed file reports `healthy` after the first check interval, with the `/health` endpoint unchanged (still returns 200).

## 0.2.4 — 2026-09-24

- **Now in 12 Hexward products.** RuleHawk, CertLight, Attack Surface Monitor, Decoy, Patchlight, Loglight, DmarcWatch, TenantWatch, Posture Report, AuditLight, TopoLight and RuleForge each have an optional ✨ Explain button, and each uses this client unchanged. AuditLight also uses `auditlight.why_disappeared` on its change report.
- Release automation: a `v*` tag publishes a GitHub release. The release carries the CHANGELOG section and a `hexward-ai-profiles-<version>.tar.gz` asset (tier profiles, `fetch-model.sh`, both compose files) with its `SHA256SUMS`. The workflow also runs the tests and a Docker build as a compile check.

## 0.2.3 — 2026-09-24

- **Deterministic severity guard.** The prompt instruction from 0.2.2 was not enough: SmolLM3 still called an `info` finding "low-severity" in one of two live runs. For `hexward.explain_finding`, the client now drops any English sentence that pairs a *different* severity word with "severity", "risk" or "priority". Examples are "low-severity", "high risk" and "severity is medium". The engine's own word is never touched. If every sentence would be dropped, the text is returned unchanged. Indonesian narration is not filtered yet; the disclaimer still applies. See `guard.go` and its tests.

## 0.2.2 — 2026-09-24

- **The engine's severity word is pinned in the request.** In a live DmarcWatch test the free-tier model called an `info` finding "low-severity". For `hexward.explain_finding` the client now repeats the exact severity right before the answer, and tells the model never to call it higher or lower.

## 0.2.1 — 2026-09-24

- **Grounding rule tightened: no arithmetic on evidence values.** In a live CertLight test, the free-tier SmolLM3 turned "expired 4182 days ago" into "11 years and 2 days". That is a derived value the evidence does not contain, and it is wrong. The system prompt now forbids calculating, converting, rounding or re-expressing numbers and dates; the model has to quote them as given.
- **More useful checklists for the generic feature.** The same test showed `what_to_verify` repeating evidence values back ("the issuer is COMODO CA"). The generic rule now asks for two to four concrete checks a person can perform, and keeps the explanation to four sentences at most.

## 0.2.0 — 2026-09-24

- **All four model tiers are verified end to end on real hardware**, in English and Bahasa
  Indonesia: `lab` (SmolLM3-3B), `smb` (Phi-4-mini-instruct), `enterprise-4b` (Qwen3-4B) and
  `enterprise-8b` (Qwen3-8B). Timings and the raw responses are in `docs/TIERS.md` and
  `docs/verification/`.
- **Generic feature `hexward.explain_finding`**, for every product on the shared `core.Finding`
  contract. `aiclient.CoreFinding` and `aiclient.NewFindingPacket` go with it, plus
  `SanitizeEvidence`: secret-like keys are dropped at every level, and strings, lists, key count
  and depth are capped. A new prompt template ships at `docker/prompts/hexward_explain_finding.tmpl`.
- **Fix: the narration language was ignored.** A bare `"language":"id"` in the packet was not
  followed by Phi-4-mini or Qwen3-4B. The client now adds an explicit instruction at the end of
  the system prompt and of the user turn. `NormalizeLanguage` accepts `id`, `id-ID`, `in` and
  `bahasa`; anything else falls back to English.
- **Tier profiles and a verified fetch script.** Each `profiles/*.env` pins a Hugging Face repo,
  commit, file size and SHA-256. `scripts/fetch-model.sh` refuses any mismatch.
- **Offline tier compose file (`docker-compose.tier.yml`).** It never downloads anything, and it
  runs read-only with all capabilities dropped, bound to loopback.
- **Dedicated AI host overlay (`docker-compose.remote.yml`).** The entrypoint supports
  `HEXWARD_AI_API_KEY_FILE` and `HEXWARD_AI_API_KEY`, refuses keys shorter than 24 characters,
  and refuses to start without a key when `HEXWARD_AI_REQUIRE_API_KEY=1`. Requests without the
  key get HTTP 401 (verified).
- **New client options.** `WithAPIKey` sends a bearer token for a remote or BYO endpoint.
  `WithDisableThinking` turns off Qwen3's reasoning mode through `chat_template_kwargs`. Both
  are omitted from the request unless set.
- `HEXWARD_AI_THREADS` and `HEXWARD_AI_TIER` entrypoint variables. New example
  `examples/explain-finding`.
- New tests cover language normalisation, evidence sanitising and bounds, packet validation,
  the language instruction's placement, the bearer header, and the thinking switch.
  `go test -race ./...` passes.

## 0.1.0 (unreleased scaffolding)

- First scaffolding of `hexward-ai`: the shared, optional AI Assist sidecar for the Hexward product line (kiriman #16, R&D → Dapur Engineering).
- `internal/aiclient` — the Go client every pilot product copies into its own repo: an OpenAI-compatible `/v1/chat/completions` caller, typed `EvidencePacket`/`Explanation` structs for both Phase 1 pilot features, timeouts, bounded retries on transport errors and HTTP 5xx only (never on 4xx or malformed JSON), and a hard client-side override of the `disclaimer` field to the canonical sentence regardless of what the model returned. Ships with `httptest`-based unit tests covering the happy path, an unreachable sidecar, retry exhaustion, non-retryable 4xx, malformed JSON at both the transport and model-content layers, and context cancellation. `go test -race ./...` is green.
- `docker/Dockerfile` + `docker/entrypoint.sh` — wraps the upstream `ghcr.io/ggml-org/llama.cpp:server` image (pinned by tag and digest, not forked) with Hexward's GBNF grammar and prompt templates. The model is never baked into the image; the entrypoint fails with a clear message if no model is mounted, unless a lab-only Hugging Face auto-download is explicitly opted into.
- `docker/grammar/response.gbnf` — grammar-constrains every response to the exact JSON shape `internal/aiclient.Explanation` expects.
- `docker/prompts/*.tmpl` — the canonical, versioned wording for both Phase 1 pilot features (RuleHawk "explain this finding", AuditLight/Posture Report "why did this finding disappear").
- `docker-compose.ai.yml` — GitHub-lab compose file, auto-downloads the free-tier model (SmolLM3-3B, Apache-2.0) from Hugging Face on first start.
- `examples/rulehawk-explain-finding`, `examples/auditlight-why-disappeared` — runnable stubs showing exactly how each pilot product would call `internal/aiclient` once it is copied into that product's own repo.
- `docs/CONCEPTS.md`, `docs/INSTALL.md`, `docs/USER-GUIDE.md`, `scripts/first-run.sh` (pre-release manual-run form — no tagged release exists yet).
- **Live inference verified end to end**, twice: a raw `curl /v1/chat/completions` request and a real `go run ./examples/auditlight-why-disappeared` call through `internal/aiclient`, both against the built `hexward-ai` image running the free-tier SmolLM3-3B model (downloaded from `ggml-org/SmolLM3-3B-GGUF`, sha256 verified against Hugging Face's own published hash). Both returned real, grammar-valid JSON matching `internal/aiclient.Explanation`.
- **Three real bugs found by that testing, fixed in this same commit, not just noted:**
  1. `docker/Dockerfile`'s `WORKDIR` broke the base image — `llama-server` resolves its shared libraries via a CWD-relative path, not `$ORIGIN`; any `WORKDIR` other than `/app` made the container exit immediately with "error while loading shared libraries". Fixed by keeping `WORKDIR /app`.
  2. `docker/grammar/response.gbnf` failed to parse — llama.cpp's GBNF parser requires a multi-line rule body to sit inside an explicit `(...)` group; a bare top-level sequence split across lines fails with "expecting name at ...". Fixed by wrapping the key/value sequence in one group.
  3. `internal/aiclient` sent no `max_tokens` — on CPU (~1 tok/s for SmolLM3-3B under this grammar), an uncapped response could run past a caller's own timeout even though the grammar guarantees eventual termination. Fixed by adding `defaultMaxTokens` (512) and a `WithMaxTokens` override, with two new regression tests.
- **Known incomplete, deliberately not claimed as done:** not wired into RuleHawk's or AuditLight's real UI (examples only); the full CI grounding gate from spec §10 (assert grammar-valid JSON and no invented tokens, assert no panic when the sidecar is killed mid-request, automated in CI) is not implemented — CI currently only builds the Docker image, it does not run it against a model, because that needs a ~2 GB download and ~90s of CPU inference whose place in CI budget is not yet decided; Phi-4-mini-instruct and Qwen3 (SMB/Enterprise tiers) have not been downloaded or run.
