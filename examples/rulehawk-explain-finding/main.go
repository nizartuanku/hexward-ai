// Command rulehawk-explain-finding is a runnable stub showing exactly how
// RuleHawk's Phase 1 pilot feature ("Explain this finding", spec §9.1)
// would call internal/aiclient once that package is copied into
// RuleHawk's own repo (spec §1/[K-2] — it is copied, not imported from
// here). Wiring this into RuleHawk's real web UI is the natural next
// job (see hexward-ai's README "What is not done yet"); this example
// exists so that job starts from working, tested client code instead of
// from a blank page.
//
// It builds one RuleHawkFinding exactly like the shadowed-rule case in
// spec §4's example, sends it to a running hexward-ai sidecar, and
// prints the result — or, if the sidecar is absent, prints exactly what
// RuleHawk's dashboard should do: render nothing extra and continue.
//
// Usage (with a sidecar already running, e.g. via docker-compose.ai.yml
// in this repo):
//
//	go run ./examples/rulehawk-explain-finding -sidecar http://127.0.0.1:8435
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/nizartuanku/hexward-ai/internal/aiclient"
)

func main() {
	sidecar := flag.String("sidecar", aiclient.DefaultBaseURL, "base URL of the hexward-ai sidecar")
	timeout := flag.Duration("timeout", 20*time.Second, "per-attempt request timeout")
	flag.Parse()

	// This is exactly the finding RuleHawk's deterministic fwrule
	// analyser already produces today for a shadowed ACL entry — see
	// core/finding.go and fwrule/analyze.go in the rulehawk repo. Only
	// the fields a human already sees in the dashboard are sent.
	finding, err := json.Marshal(aiclient.RuleHawkFinding{
		ID:               "f-0142",
		Kind:             "rule.shadowed",
		RuleIndex:        14,
		RuleText:         "permit ip 172.16.8.0/21 any",
		ShadowsRuleIndex: 8,
		ShadowedRuleText: "deny ip host 172.16.9.31 any",
	})
	if err != nil {
		log.Fatalf("marshal finding: %v", err)
	}

	evidence := aiclient.EvidencePacket{
		Feature:  aiclient.FeatureRuleHawkExplainFinding,
		Product:  "rulehawk",
		Finding:  finding,
		Language: "en",
	}

	client := aiclient.New(*sidecar, aiclient.WithTimeout(*timeout))

	ctx, cancel := context.WithTimeout(context.Background(), *timeout+5*time.Second)
	defer cancel()

	exp, err := client.Explain(ctx, evidence)
	if err != nil {
		if aiclient.IsUnavailable(err) {
			// This branch is the one that matters most: spec §3 requires
			// that an absent or unreachable sidecar leaves the product
			// working exactly as it does today. In RuleHawk's real
			// dashboard this means: render the finding as usual, simply
			// omit the "AI explanation" panel, and log at most a debug
			// line — never surface an error to the person reading the
			// report.
			fmt.Println("hexward-ai sidecar is not reachable — RuleHawk would render the finding without an AI explanation, exactly as when AI Assist is not configured.")
			return
		}
		log.Fatalf("hexward-ai returned an error: %v", err)
	}

	fmt.Println("Explanation:")
	fmt.Println(" ", exp.ExplanationText)
	fmt.Println("What to verify before touching this rule:")
	for _, item := range exp.WhatToVerify {
		fmt.Println("  -", item)
	}
	fmt.Fprintln(os.Stderr, exp.Disclaimer)
}
