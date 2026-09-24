// Command explain-finding shows how any Hexward product on the shared
// core.Finding contract calls the generic hexward.explain_finding feature
// through internal/aiclient, and doubles as a live smoke test against a
// running sidecar of any tier.
//
//	go run ./examples/explain-finding -url http://127.0.0.1:8435 -lang id
//	go run ./examples/explain-finding -url http://ai-host:8435 -key-file secrets/ai_api_key -no-thinking
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/nizartuanku/hexward-ai/internal/aiclient"
)

func main() {
	url := flag.String("url", aiclient.DefaultBaseURL, "hexward-ai sidecar base URL")
	keyFile := flag.String("key-file", "", "file holding the API key (dedicated AI host / BYO endpoint)")
	lang := flag.String("lang", "en", `narration language: "en" or "id"`)
	noThinking := flag.Bool("no-thinking", false, "disable reasoning mode (Qwen3 enterprise profiles)")
	timeout := flag.Duration("timeout", 120*time.Second, "per-attempt timeout")
	flag.Parse()

	opts := []aiclient.Option{aiclient.WithTimeout(*timeout), aiclient.WithMaxTokens(300), aiclient.WithMaxRetries(0)}
	if *keyFile != "" {
		b, err := os.ReadFile(*keyFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "read key file:", err)
			os.Exit(1)
		}
		opts = append(opts, aiclient.WithAPIKey(strings.TrimSpace(string(b))))
	}
	if *noThinking {
		opts = append(opts, aiclient.WithDisableThinking())
	}

	// A CertLight-style finding, exactly as core.Finding would carry it.
	// The private_key_path entry is there on purpose: NewFindingPacket must
	// drop it before anything is sent.
	packet, err := aiclient.NewFindingPacket("certlight", *lang, aiclient.CoreFinding{
		Fingerprint: "c1f0e2",
		Module:      "certlight",
		Check:       "cert.expiry",
		Title:       "TLS certificate expires in 12 days",
		Target:      "mail.example.com:443",
		Severity:    "high",
		Status:      "open",
		Remediation: "Renew the certificate and deploy it before the expiry date; confirm the full chain is served.",
		Evidence: map[string]any{
			"not_after":        "2026-10-06T00:00:00Z",
			"days_left":        12,
			"issuer":           "R11",
			"private_key_path": "/etc/ssl/private/mail.key",
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	start := time.Now()
	exp, err := aiclient.New(*url, opts...).Explain(context.Background(), packet)
	if err != nil {
		if aiclient.IsUnavailable(err) {
			fmt.Fprintln(os.Stderr, "sidecar unavailable — a product would simply hide the AI panel:", err)
		} else {
			fmt.Fprintln(os.Stderr, "error:", err)
		}
		os.Exit(1)
	}
	out, _ := json.MarshalIndent(exp, "", "  ")
	fmt.Println(string(out))
	fmt.Fprintf(os.Stderr, "elapsed %s\n", time.Since(start).Round(time.Millisecond))
}
