# hexward-ai — Concepts

What this sidecar is, what problem it solves, and why it is built the way it is — written for
someone meeting the idea for the first time. The command reference is in the README; this is
the reasoning behind it.

*Hexward Labs · Nizar Tuanku — Cybersecurity. · last reviewed 24 September 2026*

---

## The problem: findings are correct, but they are not always readable

A Hexward product's engine is deterministic on purpose. RuleHawk's rule analyser does not
guess whether a firewall rule is shadowed — it walks the rule base in evaluation order and
proves it. AuditLight does not guess whether a finding is fixed — it compares two runs by the
identity of each finding, not by matching text. That precision is the whole point of the
product, and it must never change.

But precision and readability are different things. "rule.shadowed, rule_index 14, shadows
8" is exactly true and not obviously useful to someone who has not audited a firewall rule
base before. "no_longer_detected" is exactly true and easy to misread as "fixed" if nobody
explains the difference. hexward-ai exists to close that one gap: turn a finding a product
already produced into a sentence a person can act on — nothing more.

## What "AI Assist" is not allowed to do

This is the part worth being precise about, because it is the part a small local model could
quietly get wrong if nobody drew the line.

- It never invents a finding. A product's deterministic engine is the only source of
  findings, full stop.
- It never sets or changes a severity. If the engine said `permissive`, the narration says
  `permissive` — it does not upgrade it to `critical` because the prose reads more alarming.
- It never decides pass/fail. Whether an assessment "passed" is a product decision made by
  code that existed before hexward-ai did.
- It never drafts a fix. RuleHawk's pilot narrates why a rule relationship matters; it does
  not write the replacement ACL line. That is a harder, riskier problem (RuleHawk's own
  README already disclaims simulating NAT/object-group interactions) and it is out of scope
  for v0 on purpose — see "What is deferred, and why" below.

If a future version of hexward-ai ever needs to do one of these things, that is a new,
separate decision with its own spec — not something this sidecar backs into quietly by
getting better at sounding confident.

## Two layers of grounding, because one is not enough

A small local model can be told not to make things up. Telling it is necessary but not
sufficient, so hexward-ai uses two independent mechanisms that fail differently:

1. **A GBNF grammar** (`docker/grammar/response.gbnf`) constrains every token the model is
   allowed to sample, so the output is always the exact JSON shape `{"explanation", "what_to_verify",
   "disclaimer"}` — never prose, never a different key, never truncated mid-object. This
   guarantees *shape*. It says nothing about whether the sentence inside `"explanation"` is
   true.
2. **A system prompt** (`internal/aiclient`'s `systemPrompt`, mirrored in
   `docker/prompts/*.tmpl`) instructs the model to use only the fields in the evidence packet
   and names, explicitly, what it must never claim. This is the layer that tries to keep the
   *content* grounded — and, being an instruction rather than a constraint, it is the weaker
   of the two. It can fail in a way the grammar cannot catch.

Because layer 2 can fail, `internal/aiclient` adds a third, deterministic backstop that does
not rely on the model at all: it overwrites the `disclaimer` field with a fixed constant
before returning, every time, regardless of what the model produced for that field. The one
sentence every user is guaranteed to see — "AI-generated summary — verify against raw
findings" — never depends on model behavior.

## Why the model is not in the image

Model weights are large (SmolLM3-3B alone is roughly 2 GB even quantized), change on a
different cadence than the sidecar's own code, and — this is the part that actually matters —
different Hexward tiers need different models under different licenses (see the table in
`README.md`). Baking one model into the image would mean rebuilding and re-publishing the
image every time a tier's model changes, and it would mean every Hexward customer downloads
weights for a tier they are not on. So the image ships empty of weights, and
`docker/entrypoint.sh` either loads a weights file the operator mounted (the only supported
path for anything that must stay fully offline) or, for a quick lab/dev smoke test only,
downloads one from Hugging Face at startup — llama.cpp itself verifies that download against
the repository's own published hash before it will load it, which is the same discipline
Hexward's own product releases already apply to their binaries.

## Why this is a separate repo, and why the client is copied, not imported

Two facts, checked directly against the other 13 product repos rather than assumed (see the
spec's §1 and [K-2]): every Hexward product is its own standalone Go module, and there is no
shared "Hexward Core" module anywhere to hold common code — even Ed25519 license validation,
the closest thing to shared infrastructure the line has, is two independently written
`license.go` files that merely agree on a wire format. `internal/aiclient` follows that exact,
already-proven pattern: written once here, copied verbatim into RuleHawk's and AuditLight's
own repos as their own `internal/aiclient`. This is not a compromise waiting for a proper
shared module — it is the same choice the license code already made, and it works for the
same reason: each product stays a genuinely standalone, self-contained binary, which is a
promise Hexward makes about every product in the line.

## Why it is a sidecar and not code glued into a product binary

If hexward-ai's inference code lived inside RuleHawk's binary, RuleHawk would inherit a large
model runtime, a much bigger binary, and a dependency on hardware (or at least RAM) headroom
it does not need for its actual job of parsing firewall configs. As a separate process behind
a small HTTP client, a product that never enables AI Assist pays none of that cost, and a
product that does can point at any OpenAI-compatible server — this sidecar, a different one,
or (Enterprise tier) a customer's own endpoint — without a rebuild.

## What happens when the sidecar is absent

Exactly what happens today, before this feature existed. `internal/aiclient.New` never dials
anything — it only creates a struct. `Explain` returns `aiclient.ErrUnavailable` (checkable
with `aiclient.IsUnavailable`) for a connection refused, a timeout, or repeated HTTP 5xx after
retries. A product's UI is expected to treat that exactly like AI Assist not being configured:
render the finding as usual, skip the AI panel, and — this is the part worth stating plainly —
never crash and never show the user an error for a feature they may not even know exists.

## What is deferred, and why (not scope creep — a decision)

- **CMDB/ITSM integration** (asset owner, change ticket, business criticality) — no Hexward
  product collects this data today. Wiring it in is a data-pipeline project with its own
  spec, not something an AI feature can retrofit.
- **Auto-drafted remediation** (a ready-to-apply ACL/NAT snippet) — needs a policy
  evaluator/simulator that does not exist, and small local models are unreliable at precise
  object-group/NAT reasoning. Also, RuleHawk's own README already disclaims simulating this.
- **RAG over vendor docs / CIS Benchmarks / MITRE ATT&CK** — a real feature with real scope
  (corpus curation, freshness, retrieval-quality risk) that deserves its own spec once the
  narration-only pattern here is proven, not a feature bolted onto v0 for completeness.

## Terms used above

- **Sidecar** — a separate process that runs alongside a product (in its own container),
  reachable over the network, rather than code linked into the product's own binary.
- **GBNF grammar** — a formal grammar (Backus-Naur Form, as extended by llama.cpp) that
  constrains which tokens a language model is allowed to output next, used here to force
  syntactically valid JSON in an exact shape.
- **Grounding** — keeping a model's output limited to facts actually present in the input it
  was given, rather than facts it may have learned during training or invented to sound
  complete.
- **OpenAI-compatible** — implementing the same HTTP request/response shape as OpenAI's
  `/v1/chat/completions` API, so any server that speaks it (llama.cpp, Ollama, vLLM, or a
  customer's own endpoint) can be swapped in without changing the calling code.
