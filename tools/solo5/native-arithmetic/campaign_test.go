package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func selectedPlan() campaignPlan {
	return campaignPlan{Schema: "fenrir.solo5.selected-campaign-plan/1", DeclaredHands: 13, DeclaredGenerated: 16, PriorExecutions: 15, PriorBuilds: 11, Cases: []campaignCase{{Name: "last_step", Family: "hand", Artifact: "a", Input: "i", Fuel: 4, Modes: []string{"normal"}, Replay: true}}}
}
func TestCampaignPlanBounds(t *testing.T) {
	if e := validateCampaignPlan(selectedPlan()); e != nil {
		t.Fatal(e)
	}
	for name, mutate := range map[string]func(*campaignPlan){
		"fuel":           func(p *campaignPlan) { p.Cases[0].Fuel = 201 },
		"mode":           func(p *campaignPlan) { p.Cases[0].Modes = []string{"normal", "normal"} },
		"family":         func(p *campaignPlan) { p.Cases[0].Family = "peer" },
		"name escape":    func(p *campaignPlan) { p.Cases[0].Name = "../escape" },
		"execution cap":  func(p *campaignPlan) { p.PriorExecutions = 99 },
		"build cap":      func(p *campaignPlan) { p.PriorBuilds = 40 },
		"declaration":    func(p *campaignPlan) { p.DeclaredGenerated = 1 },
		"duplicate case": func(p *campaignPlan) { p.Cases = append(p.Cases, p.Cases[0]) },
	} {
		t.Run(name, func(t *testing.T) {
			p := selectedPlan()
			mutate(&p)
			if validateCampaignPlan(p) == nil {
				t.Fatal("unsafe plan admitted")
			}
		})
	}
}

func TestCampaignCancellationPersistsPartialWithoutLaunch(t *testing.T) {
	root := t.TempDir()
	output := filepath.Join(root, "build/solo5/partial")
	if e := os.MkdirAll(output, 0700); e != nil {
		t.Fatal(e)
	}
	planPath := filepath.Join(root, "build/solo5/plan.json")
	p := selectedPlan()
	if e := writeJSONFresh(planPath, p); e != nil {
		t.Fatal(e)
	}
	before, e := snapshot([]string{planPath})
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if e = executeCampaign(ctx, root, "missing", "missing", output, planPath, p, before); e != context.Canceled {
		t.Fatal(e)
	}
	var s campaignSummary
	if e = loadJSON(filepath.Join(output, "summary.json"), &s); e != nil {
		t.Fatal(e)
	}
	if s.Status != "INCOMPLETE" || s.Error != "context canceled" || s.Executions != 0 || s.Builds != 0 || s.Cleanup != "confirmed" {
		t.Fatalf("false completed selection: %+v", s)
	}
	if e = campaignInspectCLI([]string{"--root", root, "--summary", filepath.Join(output, "summary.json")}); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(planPath, []byte("drift"), 0600); e != nil {
		t.Fatal(e)
	}
	if campaignInspectCLI([]string{"--root", root, "--summary", filepath.Join(output, "summary.json")}) == nil {
		t.Fatal("saved evidence drift admitted")
	}
}
