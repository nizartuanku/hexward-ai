# hexward-ai — User Guide

This guide is for the person integrating AI Assist into a Hexward product, or operating the
sidecar. If you are looking for the reasoning behind the design, see `docs/CONCEPTS.md`. If
you are looking for how to get the container running, see `docs/INSTALL.md`.

## What you get

One HTTP service, `hexward-ai`, that answers `POST /v1/chat/completions` (OpenAI-compatible)
and turns one finding your product's engine already produced into a short, plain-language
explanation. It is optional: nothing in the Hexward line requires it, and every pilot product
works exactly the same with it turned off.

## The only two things it currently does (Phase 1 pilot, spec §9)

1. **RuleHawk — "Explain this finding."** Given one shadowed/permissive rule finding, it
   explains in plain language why the rule relationship matters and lists what to verify
   before touching the rule. It never drafts a replacement rule.
2. **AuditLight / Posture Report — "Why did this finding disappear?"** Given a finding's
   coverage status (`fixed` / `no_longer_detected` / `check_failed` / `target_skipped` — a
   classification your product already made), it explains in plain language which of those
   happened, so a report never reads better than it is.

Nothing else is implemented. If you are picturing a chat window where you ask arbitrary
questions about your infrastructure, that is not this — see `docs/CONCEPTS.md` "What is
deferred, and why".

## Calling it from a product

Copy `internal/aiclient/` from this repo into your product's own repo, at the same path
(`internal/aiclient/`) — see spec [K-2] for why it is copied rather than imported. Then:

```go
import "github.com/<yourproduct>/internal/aiclient"

finding, _ := json.Marshal(aiclient.RuleHawkFinding{
    ID:               "f-0142",
    Kind:             "rule.shadowed",
    RuleIndex:        14,
    RuleText:         "permit ip 172.16.8.0/21 any",
    ShadowsRuleIndex: 8,
    ShadowedRuleText: "deny ip host 172.16.9.31 any",
})

client := aiclient.New(aiclient.DefaultBaseURL) // http://127.0.0.1:8435

exp, err := client.Explain(ctx, aiclient.EvidencePacket{
    Feature: aiclient.FeatureRuleHawkExplainFinding,
    Product: "rulehawk",
    Finding: finding,
})
if err != nil {
    if aiclient.IsUnavailable(err) {
        // Render the finding as usual. Skip the AI panel. Do not show an error.
        return
    }
    // A non-nil, non-Unavailable error usually means a caller bug (see
    // ErrInvalidRequest) or a malformed sidecar response — log it, still
    // render the finding without the AI panel, still do not crash.
}
// exp.ExplanationText, exp.WhatToVerify, exp.Disclaimer are ready to render.
```

Full runnable versions of both pilot calls are in `examples/rulehawk-explain-finding/main.go`
and `examples/auditlight-why-disappeared/main.go`.

## Rendering the result

Every response carries a `Disclaimer` field. Show it, verbatim, next to the explanation —
`internal/aiclient` overwrites it with the fixed sentence "AI-generated summary — verify
against raw findings" itself, so you can render `exp.Disclaimer` directly and trust it says
exactly that, regardless of what the model returned. Do not paraphrase it away, shrink it to a
tooltip nobody reads, or drop it because "the UI already has a note somewhere else" — it is
the one honesty signal a user sees on every AI-generated line, and spec §7 requires it.

## Configuration your product should expose

- **Sidecar URL** — default `http://127.0.0.1:8435` (`aiclient.DefaultBaseURL`); an operator
  running the sidecar on a different host or port needs to be able to change this without a
  rebuild. Use `aiclient.New(url)`.
- **A visible on/off switch** — AI Assist is opt-in (spec §8: "optional and disabled by
  default"). Do not call `Explain` unless the operator turned this on, even if the
  `ai_assist` license flag is present — a present license capability is permission to offer
  the feature, not a requirement to always use it.
- **Timeout** — `aiclient.WithTimeout` bounds a single HTTP attempt. The default (20s) assumes
  CPU inference on a modest host; lower it if your UI needs a snappier "no answer yet" fallback.

## Licensing

A new `ai_assist` boolean is added to the existing Ed25519 license payload — the same issuer
keypair, no new licensing system (spec §6). The free/GitHub edition of a pilot product never
sets this flag. hexward-ai itself never checks a license; gating is entirely the calling
product's decision about whether to call `Explain` at all.

## Honest limits

- AI Assist is optional and disabled by default.
- It needs additional host resources beyond the product itself — see `README.md` "Server
  requirements".
- It runs entirely offline once a model is mounted; no data leaves the network running it
  (the one exception, opt-in and lab-only, is downloading model weights from Hugging Face —
  see `docs/INSTALL.md` step 3).
- The output is generated text. It can be wrong even though the grammar makes it syntactically
  valid JSON. It summarizes and lists what to check; it does not replace the underlying
  finding, and it is never the only thing you should read before acting.
- **A live model WAS run in this session** (SmolLM3-3B, free tier) and answered a real request
  end to end through the built Docker image and the real `internal/aiclient` Go client — see
  the README's "What was verified end to end". On this VM's CPU, generation ran at roughly
  1 token/second; plan for that on CPU-only hosts, and see `internal/aiclient.WithMaxTokens`
  for the cap that keeps a slow response from outliving a caller's timeout.
