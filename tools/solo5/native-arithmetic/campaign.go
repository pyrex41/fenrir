package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"
	"time"
)

// Selected-case development aggregation only. Full hardening and hand-derived
// acceptance are deliberately not promoted by this report.
type campaignCase struct {
	Name     string   `json:"name"`
	Family   string   `json:"family"`
	Artifact string   `json:"artifact"`
	Input    string   `json:"input"`
	Fuel     int      `json:"fuel"`
	Modes    []string `json:"modes"`
	Replay   bool     `json:"replay"`
}
type campaignPlan struct {
	Schema            string         `json:"schema"`
	DeclaredHands     int            `json:"declared_hands"`
	DeclaredGenerated int            `json:"declared_generated"`
	PriorExecutions   int            `json:"prior_executions"`
	PriorBuilds       int            `json:"prior_two_build_compilations"`
	Cases             []campaignCase `json:"cases"`
}
type campaignObservation struct {
	Name        string `json:"name"`
	Family      string `json:"family"`
	Mode        string `json:"mode"`
	Session     string `json:"session"`
	Execution   string `json:"execution"`
	Conformance string `json:"conformance"`
	Replay      string `json:"replay"`
}
type campaignSummary struct {
	Schema        string                `json:"schema"`
	Qualification string                `json:"qualification"`
	Status        string                `json:"status"`
	Cleanup       string                `json:"cleanup"`
	Error         string                `json:"first_error"`
	Limitations   []string              `json:"limitations"`
	Plan          campaignPlan          `json:"plan"`
	Executions    int                   `json:"execution_attempts"`
	Builds        int                   `json:"two_build_attempts"`
	Observations  []campaignObservation `json:"observations"`
	Evidence      map[string]string     `json:"evidence"`
	SourcesBefore map[string]string     `json:"sources_before"`
	SourcesAfter  map[string]string     `json:"sources_after"`
}

func validateCampaignPlan(p campaignPlan) error {
	if p.Schema != "fenrir.solo5.selected-campaign-plan/1" || p.DeclaredHands != 13 || p.DeclaredGenerated != 16 || len(p.Cases) == 0 || len(p.Cases) > 29 || p.PriorExecutions < 0 || p.PriorBuilds < 0 {
		return fmt.Errorf("CampaignPlanBounds")
	}
	executions := p.PriorExecutions
	builds := p.PriorBuilds
	names := map[string]bool{}
	validName := regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	hands, generated := 0, 0
	for _, c := range p.Cases {
		if !validName.MatchString(c.Name) || names[c.Name] || c.Artifact == "" || c.Input == "" || c.Fuel < 0 || c.Fuel > 200 || len(c.Modes) == 0 || len(c.Modes) > 2 {
			return fmt.Errorf("CampaignCaseBounds")
		}
		names[c.Name] = true
		switch c.Family {
		case "hand":
			hands++
		case "generated":
			generated++
		default:
			return fmt.Errorf("CampaignFamily")
		}
		modes := map[string]bool{}
		for _, mode := range c.Modes {
			if (mode != "normal" && mode != "mutant") || modes[mode] {
				return fmt.Errorf("CampaignMode")
			}
			modes[mode] = true
			executions++
			if c.Replay {
				executions++
			}
		}
		builds++
	}
	if hands > 13 || generated > 16 || executions > 100 || builds > 40 {
		return fmt.Errorf("CampaignAggregateCap")
	}
	return nil
}

func campaignCLI(args []string) error {
	f := flag.NewFlagSet("campaign", flag.ContinueOnError)
	root := f.String("root", ".", "repository root")
	planPath := f.String("plan", "", "closed selected-case plan")
	dependency := f.String("transport-build", "", "immutable control dependency")
	shen := f.String("shen-executable", "", "existing Shen executable")
	output := f.String("output-dir", "", "fresh campaign directory")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *planPath == "" || *dependency == "" || *shen == "" || *output == "" {
		return fmt.Errorf("CampaignFlags")
	}
	var e error
	*root, e = filepath.Abs(*root)
	if e != nil {
		return e
	}
	*root, e = filepath.EvalSymlinks(*root)
	if e != nil {
		return e
	}
	for _, p := range []*string{planPath, dependency, shen, output} {
		*p, e = filepath.Abs(*p)
		if e != nil {
			return e
		}
	}
	*planPath, e = sealedPath(filepath.Join(*root, "build/solo5"), *planPath)
	if e != nil {
		return e
	}
	var plan campaignPlan
	if e = loadJSON(*planPath, &plan); e != nil {
		return e
	}
	if e = validateCampaignPlan(plan); e != nil {
		return e
	}
	// Preflight all selected data paths before admitting any execution.
	for i := range plan.Cases {
		c := &plan.Cases[i]
		for _, p := range []*string{&c.Artifact, &c.Input} {
			if !filepath.IsAbs(*p) {
				*p = filepath.Join(*root, *p)
			}
			*p, e = sealedPath(*root, *p)
			if e != nil {
				return e
			}
			var raw any
			if e = loadJSON(*p, &raw); e != nil {
				return e
			}
		}
	}
	if _, e = admitDependency(*root, *dependency); e != nil {
		return e
	}
	host, e := hostSources(*root)
	if e != nil {
		return e
	}
	sources := append(host, *planPath, *dependency, *shen, filepath.Join(filepath.Dir(filepath.Dir(*shen)), "lib/shen-scheme/shen.boot"))
	for _, name := range []string{"admit.mjs", "lower.mjs", "hand-cases.mjs", "generated-cases.mjs", "verify-hands.mjs"} {
		sources = append(sources, filepath.Join(*root, "tools/solo5/native-arithmetic", name))
	}
	sources = append(sources, requiredDependencyFiles(*root)...)
	for _, p := range []string{"models/tc0/arithmetic.shen", "models/tc0/expression-machine.shen", "tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs", "backends/solo5/native-arithmetic/machine.h", "backends/solo5/native-arithmetic/machine.c", "backends/solo5/native-arithmetic/format.h", "backends/solo5/native-arithmetic/format.c", "backends/solo5/native-arithmetic/guest.c", "backends/solo5/protocol.h", "backends/solo5/protocol.c"} {
		sources = append(sources, filepath.Join(*root, p))
	}
	node, e := exec.LookPath("node")
	if e != nil {
		return e
	}
	self, e := os.Executable()
	if e != nil {
		return e
	}
	sources = append(sources, node, self)
	for _, c := range plan.Cases {
		sources = append(sources, c.Artifact, c.Input)
	}
	before, e := snapshot(sources)
	if e != nil {
		return e
	}
	if e = freshDirectory(*root, *output); e != nil {
		return e
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return executeCampaign(ctx, *root, *dependency, *shen, *output, *planPath, plan, before)
}

func executeCampaign(ctx context.Context, root, dependency, shen, output, planPath string, plan campaignPlan, before map[string]string) (err error) {
	summary := campaignSummary{Schema: "fenrir.solo5.selected-campaign-development/1", Qualification: "UNKNOWN", Status: "INCOMPLETE", Cleanup: "confirmed", Plan: plan, Observations: []campaignObservation{}, Evidence: map[string]string{}, SourcesBefore: before, Limitations: []string{
		"Selected cases only: full 13-hand/16-generated matrix and cold repetition obligations may be unevaluated.",
		"No independent hand outcome/emission/rule verification in this command; Shen/native observations are separate.",
		"H1/H2 full admission/lifecycle matrix and independent repair remain incomplete; no qualification or native-counter closure.",
	}}
	retain := func(p string) error {
		h, e := digest(p)
		if e == nil {
			summary.Evidence[p] = h
		}
		return e
	}
	if e := retain(planPath); e != nil {
		return e
	}
	defer func() {
		if err != nil {
			summary.Error = err.Error()
		}
		after, e := snapshotKeys(before)
		summary.SourcesAfter = after
		if e != nil || !sameHashes(before, after) {
			if err == nil {
				err = fmt.Errorf("CampaignSourceDrift: %v", e)
				summary.Error = err.Error()
			}
		}
		if e := writeJSONFresh(filepath.Join(output, "summary.json"), summary); e != nil {
			err = e
		}
	}()
	for _, c := range plan.Cases {
		if e := ctx.Err(); e != nil {
			return e
		}
		header := filepath.Join(output, c.Name+".h")
		log, e := synchronous(root, []string{"node", filepath.Join(root, "tools/solo5/native-arithmetic/lower.mjs"), c.Artifact, c.Input, header}, 30*time.Second)
		if we := writeJSONFresh(filepath.Join(output, c.Name+"-lower.json"), log); we != nil {
			return we
		}
		if e != nil {
			return e
		}
		if e = retain(header); e != nil {
			return e
		}
		if e = ctx.Err(); e != nil {
			return e
		}
		summary.Builds++ // Count attempts, including failed two-build compilations.
		buildDir := filepath.Join(output, c.Name+"-build")
		if _, e = compileGuest(root, header, buildDir, dependency, c.Fuel); e != nil {
			summary.Cleanup = "unresolved"
			return e
		}
		build := filepath.Join(buildDir, "build.json")
		for _, p := range []string{build, filepath.Join(buildDir, "guest.spt"), filepath.Join(buildDir, "diagnostics.json")} {
			if e = retain(p); e != nil {
				return e
			}
		}
		for _, mode := range c.Modes {
			if e = ctx.Err(); e != nil {
				return e
			}
			session := filepath.Join(output, c.Name+"-"+mode+"-session.json")
			commonArgs := []string{"--root", root, "--build-report", build, "--artifact", c.Artifact, "--input", c.Input, "--shen-executable", shen, "--mode", mode}
			summary.Executions++ // Conservative reservation before admission/oracle.
			if e = sessionCLIContext(ctx, append(append([]string{}, commonArgs...), "--output", session)); e != nil {
				summary.Cleanup = "unresolved"
				return e
			}
			if e = retain(session); e != nil {
				return e
			}
			var b sessionBundle
			if e = loadJSON(session, &b); e != nil {
				return e
			}
			row := campaignObservation{Name: c.Name, Family: c.Family, Mode: mode, Session: session, Execution: b.Result.Execution, Conformance: b.Result.Conformance, Replay: "NotExecuted"}
			summary.Observations = append(summary.Observations, row)
			if b.Result.Cleanup != "confirmed" {
				summary.Cleanup = "unresolved"
				return fmt.Errorf("CampaignCleanup")
			}
			if b.Result.Execution == "HarnessCanceled" {
				return context.Canceled
			}
			if b.Result.Conformance != "Admitted" && b.Result.Conformance != "Diverged" {
				return fmt.Errorf("CampaignInfrastructure: %s", b.Result.Execution)
			}
			if c.Replay {
				if e = ctx.Err(); e != nil {
					return e
				}
				replay := filepath.Join(output, c.Name+"-"+mode+"-replay.json")
				summary.Executions++
				if e = replayCLIContext(ctx, append(append([]string{}, commonArgs...), "--original", session, "--output", replay)); e != nil {
					summary.Cleanup = "unresolved"
					return e
				}
				if e = retain(replay); e != nil {
					return e
				}
				summary.Observations[len(summary.Observations)-1].Replay = "Exact"
			}
		}
	}
	return nil
}

func snapshotKeys(before map[string]string) (map[string]string, error) {
	paths := []string{}
	for p := range before {
		paths = append(paths, p)
	}
	return snapshot(paths)
}
func sameHashes(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for p, h := range a {
		if b[p] != h {
			return false
		}
	}
	return true
}

func campaignInspectCLI(args []string) error {
	f := flag.NewFlagSet("campaign-inspect", flag.ContinueOnError)
	root := f.String("root", ".", "repository root")
	path := f.String("summary", "", "saved summary; never reruns guests")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *path == "" {
		return fmt.Errorf("CampaignInspectFlags")
	}
	r, e := filepath.Abs(*root)
	if e != nil {
		return e
	}
	var s campaignSummary
	if e = loadJSON(*path, &s); e != nil {
		return e
	}
	if s.Schema != "fenrir.solo5.selected-campaign-development/1" || s.Qualification != "UNKNOWN" || s.Status != "INCOMPLETE" || (s.Cleanup != "confirmed" && s.Cleanup != "unresolved") || s.Executions < 0 || s.Builds < 0 || s.Executions+s.Plan.PriorExecutions > 100 || s.Builds+s.Plan.PriorBuilds > 40 || len(s.Evidence) == 0 {
		return fmt.Errorf("CampaignSummaryBounds")
	}
	if e = validateCampaignPlan(s.Plan); e != nil {
		return e
	}
	expectedRows, expectedExecutions := 0, 0
	for _, c := range s.Plan.Cases {
		expectedRows += len(c.Modes)
		expectedExecutions += len(c.Modes)
		if c.Replay {
			expectedExecutions += len(c.Modes)
		}
	}
	if s.Builds > len(s.Plan.Cases) || s.Executions > expectedExecutions || len(s.Observations) > expectedRows || len(s.Observations) > s.Executions || (s.Error == "" && (len(s.Observations) != expectedRows || s.Executions != expectedExecutions || s.Builds != len(s.Plan.Cases))) {
		return fmt.Errorf("CampaignSummaryCounts")
	}
	seen := map[string]bool{}
	for _, o := range s.Observations {
		key := o.Name + ":" + o.Mode
		if seen[key] {
			return fmt.Errorf("CampaignSummaryDuplicateObservation")
		}
		seen[key] = true
		found := false
		for _, c := range s.Plan.Cases {
			if c.Name == o.Name && c.Family == o.Family {
				for _, m := range c.Modes {
					if m == o.Mode {
						found = true
					}
				}
			}
		}
		if !found || s.Evidence[o.Session] == "" {
			return fmt.Errorf("CampaignSummaryUnboundObservation")
		}
		var b sessionBundle
		if e = loadJSON(o.Session, &b); e != nil {
			return e
		}
		if b.Schema != "fenrir.solo5.native-arithmetic-development/1" || b.Qualification != "UNKNOWN" || b.Result.Execution != o.Execution || b.Result.Conformance != o.Conformance {
			return fmt.Errorf("CampaignObservationContradiction")
		}
	}
	for p, h := range s.Evidence {
		actual, e := sealedPath(filepath.Join(r, "build/solo5"), p)
		if e != nil {
			return e
		}
		got, e := digest(actual)
		if e != nil || got != h {
			return fmt.Errorf("CampaignEvidenceDrift: %s", p)
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"qualification": "UNKNOWN", "status": "INCOMPLETE", "saved_evidence": "hashes-verified-not-rerun", "execution_attempts": strconv.Itoa(s.Executions), "cleanup": s.Cleanup})
}
