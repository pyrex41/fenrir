package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCampaignPartialCountsCannotExceedSelection(t *testing.T) {
	for _, kind := range []string{"builds", "executions"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			base := filepath.Join(root, "build/solo5")
			if e := os.MkdirAll(base, 0700); e != nil {
				t.Fatal(e)
			}
			planPath := filepath.Join(base, "plan.json")
			plan := selectedPlan()
			if e := writeJSONFresh(planPath, plan); e != nil {
				t.Fatal(e)
			}
			hash, e := digest(planPath)
			if e != nil {
				t.Fatal(e)
			}
			s := campaignSummary{Schema: "fenrir.solo5.selected-campaign-development/1", Qualification: "UNKNOWN", Status: "INCOMPLETE", Cleanup: "confirmed", Error: "retained failure", Plan: plan, Observations: []campaignObservation{}, Evidence: map[string]string{planPath: hash}}
			// The selected ceiling remains inspectable as partial evidence, not acceptance.
			s.Builds = 1
			s.Executions = 2
			boundary := filepath.Join(base, "boundary.json")
			if e := writeJSONFresh(boundary, s); e != nil {
				t.Fatal(e)
			}
			if e := campaignInspectCLI([]string{"--root", root, "--summary", boundary}); e != nil {
				t.Fatalf("selected boundary rejected: %v", e)
			}
			if kind == "builds" {
				s.Builds = 2
			} else {
				s.Builds = 1
				s.Executions = 3
			}
			path := filepath.Join(base, "summary.json")
			if e := writeJSONFresh(path, s); e != nil {
				t.Fatal(e)
			}
			if e := campaignInspectCLI([]string{"--root", root, "--summary", path}); e == nil {
				t.Fatal("partial counts exceeding selected reservations admitted")
			}
		})
	}
}
