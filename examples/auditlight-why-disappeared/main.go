// Command auditlight-why-disappeared is a runnable stub showing exactly
// how AuditLight / Posture Report's Phase 1 pilot feature ("Why did this
// finding disappear?", spec §9.2) would call internal/aiclient once that
// package is copied into AuditLight's own repo (spec §1/[K-2]). Wiring
// this into AuditLight's real Change Report view is the natural next
// job; see hexward-ai's README "What is not done yet".
//
// It builds one AuditLightDisappearance with status "no_longer_detected"
// — the exact case the pilot exists for, because it is the one most
// likely to be misread as "fixed" if left unexplained — sends it to a
// running hexward-ai sidecar, and prints the result.
//
// Usage:
//
//	go run ./examples/auditlight-why-disappeared -sidecar http://127.0.0.1:8435
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

	// AuditLight's own Change Report already classified this finding —
	// see docs/CONCEPTS.md "The report nobody gives you" in the
	// auditlight repo. hexward-ai is handed the classification, it does
	// not make it.
	disappearance, err := json.Marshal(aiclient.AuditLightDisappearance{
		FindingID:   "af-2291",
		Description: "TLS certificate on 10.0.4.12:443 expires within 14 days",
		LastSeenRun: "2026-08-24T09:00:00Z",
		CurrentRun:  "2026-09-24T09:00:00Z",
		Status:      aiclient.CoverageNoLongerDetected,
		Detail:      "certificate check ran successfully on both dates; the certificate observed on the current run has 97 days remaining",
	})
	if err != nil {
		log.Fatalf("marshal disappearance: %v", err)
	}

	evidence := aiclient.EvidencePacket{
		Feature:  aiclient.FeatureAuditLightWhyDisappeared,
		Product:  "auditlight",
		Finding:  disappearance,
		Language: "en",
	}

	client := aiclient.New(*sidecar, aiclient.WithTimeout(*timeout))

	ctx, cancel := context.WithTimeout(context.Background(), *timeout+5*time.Second)
	defer cancel()

	exp, err := client.Explain(ctx, evidence)
	if err != nil {
		if aiclient.IsUnavailable(err) {
			fmt.Println("hexward-ai sidecar is not reachable — the Change Report would render this row exactly as it does today, without an AI explanation.")
			return
		}
		log.Fatalf("hexward-ai returned an error: %v", err)
	}

	fmt.Println("Explanation:")
	fmt.Println(" ", exp.ExplanationText)
	fmt.Println("What to verify before trusting this either way:")
	for _, item := range exp.WhatToVerify {
		fmt.Println("  -", item)
	}
	fmt.Fprintln(os.Stderr, exp.Disclaimer)
}
