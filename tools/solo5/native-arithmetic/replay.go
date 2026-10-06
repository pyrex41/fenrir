package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"time"
)

type sessionBundle struct {
	Schema        string            `json:"schema"`
	Qualification string            `json:"qualification"`
	Sources       map[string]string `json:"sources"`
	BuildHash     string            `json:"build_sha256"`
	Model         referenceResult   `json:"model"`
	Result        sessionResult     `json:"result"`
}

func validateTape(data map[string]any, model referenceResult, mode string, tape sessionResult) error {
	if tape.Cleanup != "confirmed" {
		return fmt.Errorf("ReplayCleanup")
	}
	if e := validateRecordedSessionLaunch(tape.Command, mode, "", ""); e != nil {
		return e
	}
	rows, replies := expectations(data, model, mode)
	if len(tape.Trace) == 0 || len(tape.Trace) > len(rows) {
		return fmt.Errorf("ReplayTraceBounds")
	}
	mismatch := -1
	wantChoices := []map[string]any{}
	for i, row := range tape.Trace {
		if !reflect.DeepEqual(row, rows[i]) {
			if i != len(tape.Trace)-1 || mismatch >= 0 {
				return fmt.Errorf("ReplayPrefixMismatch")
			}
			mismatch = i
			break
		}
		if reply, ok := replies[i]; ok {
			wantChoices = append(wantChoices, reply)
		}
	}
	if !reflect.DeepEqual(tape.Choices, wantChoices) {
		return fmt.Errorf("ReplayChoicesMissingExtraReorderedOrIncompatible")
	}
	if mismatch >= 0 {
		observed := tape.Trace[mismatch]
		wantError := map[string]any{"kind": "RecordMismatch", "record_index": strconv.Itoa(mismatch), "epoch": observed["epoch"], "expected": rows[mismatch], "observed": observed}
		if tape.Execution != "StoppedAtDivergence" || tape.Conformance != "Diverged" || !reflect.DeepEqual(tape.FirstError, wantError) {
			return fmt.Errorf("ReplayDivergenceBoundary")
		}
	} else if len(tape.Trace) != len(rows) || tape.Execution != model.Execution || tape.Conformance != "Admitted" || tape.FirstError != nil || tape.Exit != "0" {
		return fmt.Errorf("ReplayIncomplete")
	}
	return nil
}
func replayCLI(args []string) error {
	return replayCLIContext(context.Background(), args)
}

func replayCLIContext(ctx context.Context, args []string) error {
	f := flag.NewFlagSet("replay", flag.ContinueOnError)
	root := f.String("root", ".", "repository root")
	original := f.String("original", "", "retained development session")
	build := f.String("build-report", "", "original build report")
	artifact := f.String("artifact", "", "original artifact")
	input := f.String("input", "", "original input")
	shen := f.String("shen-executable", "", "original Shen executable")
	output := f.String("output", "", "fresh replay report")
	mode := f.String("mode", "normal", "original candidate mode")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *original == "" || *build == "" || *artifact == "" || *input == "" || *shen == "" || *output == "" {
		return fmt.Errorf("ReplayFlags")
	}
	if *mode != "normal" && *mode != "mutant" {
		return fmt.Errorf("CandidateMode")
	}
	for _, p := range []*string{root, original, build, artifact, input, shen, output} {
		a, e := filepath.Abs(*p)
		if e != nil {
			return e
		}
		*p = a
	}
	r, e := filepath.EvalSymlinks(*root)
	if e != nil {
		return e
	}
	*root = r
	parent, e := filepath.EvalSymlinks(filepath.Dir(*output))
	if e != nil {
		return e
	}
	if !within(filepath.Join(*root, "build/solo5"), filepath.Join(parent, filepath.Base(*output))) {
		return fmt.Errorf("ReplayOutputOutsideBuild")
	}
	if _, e = os.Lstat(*output); !os.IsNotExist(e) {
		return fmt.Errorf("FreshReplayOutput")
	}
	var old sessionBundle
	if e = loadJSON(*original, &old); e != nil {
		return e
	}
	if old.Schema != "fenrir.solo5.native-arithmetic-development/1" || old.Qualification != "UNKNOWN" || len(old.Sources) == 0 {
		return fmt.Errorf("ReplaySchema")
	}
	files, e := requiredSessionFiles(*root, *build, *artifact, *input, *shen)
	if e != nil {
		return e
	}
	required, e := snapshot(files)
	if e != nil {
		return e
	}
	if e = verifyReplayInventory(required, old.Sources); e != nil {
		return e
	}
	before := map[string]string{}
	for p, h := range old.Sources {
		actual, e := digest(p)
		if e != nil || actual != h {
			return fmt.Errorf("ReplaySourceIdentity: %s", p)
		}
		before[p] = actual
	}
	// The executable and every supplied launch input must be explicitly bound,
	// not simply present somewhere in an unrelated source map.
	self, e := os.Executable()
	if e != nil {
		return e
	}
	for _, p := range []string{self, *build, *artifact, *input, *shen, filepath.Join(filepath.Dir(*build), "guest.spt")} {
		real, e := filepath.EvalSymlinks(p)
		if e != nil {
			return e
		}
		if _, ok := before[real]; !ok {
			return fmt.Errorf("ReplayUnboundLaunchInput: %s", p)
		}
	}
	bh, e := digest(*build)
	if e != nil || bh != old.BuildHash {
		return fmt.Errorf("ReplayBuildIdentity")
	}
	originalHash, e := digest(*original)
	if e != nil {
		return e
	}
	report, data, e := admitNative(*root, *build, *artifact, *input)
	if e != nil {
		return e
	}
	if e := validateRecordedSessionLaunch(old.Result.Command, *mode, report.Image, filepath.Join(filepath.Dir(*build), "guest.spt")); e != nil {
		return e
	}
	fuel, e := parseBuildFuel(report.Fuel)
	if e != nil {
		return e
	}
	var program map[string]any
	if e = loadJSON(*artifact, &program); e != nil {
		return e
	}
	model, e := reference(*root, *shen, program, data["input"], fuel)
	if e != nil {
		return e
	}
	if !reflect.DeepEqual(model.Steps, old.Model.Steps) || model.Execution != old.Model.Execution || !reflect.DeepEqual(model.Outcome, old.Model.Outcome) || !reflect.DeepEqual(model.Command, old.Model.Command) {
		return fmt.Errorf("ReplayModelIdentityOrObservations")
	}
	if e = validateTape(data, model, *mode, old.Result); e != nil {
		return e
	}
	result, e := runSessionContext(ctx, *root, report, data, model, filepath.Join(filepath.Dir(*build), "guest.spt"), *mode, 30*time.Second, &old.Result)
	if e != nil {
		return e
	}
	exact := reflect.DeepEqual(result.Trace, old.Result.Trace) && reflect.DeepEqual(result.Choices, old.Result.Choices) && reflect.DeepEqual(result.FirstError, old.Result.FirstError) && result.Execution == old.Result.Execution && result.Conformance == old.Result.Conformance && result.StdoutHash == old.Result.StdoutHash
	// Docker CLI's SIGKILL exit code can differ across hosts; the semantic
	// divergence boundary is captured. Successful completion must remain exit0.
	if old.Result.Execution != "StoppedAtDivergence" {
		exact = exact && result.Exit == old.Result.Exit
	}
	for p, h := range before {
		actual, e := digest(p)
		if e != nil || actual != h {
			return fmt.Errorf("ReplaySourceDrift")
		}
	}
	h, e := digest(*original)
	if e != nil || h != originalHash {
		return fmt.Errorf("OriginalTapeDrift")
	}
	if _, _, e = admitNative(*root, *build, *artifact, *input); e != nil {
		return e
	}
	verdict := "Mismatch"
	if exact {
		verdict = "Exact"
	}
	bundle := map[string]any{"schema": "fenrir.solo5.native-arithmetic-replay/1", "qualification": "UNKNOWN", "original_sha256": originalHash, "sources": before, "replay": verdict, "model": model, "result": result, "cleanup": result.Cleanup}
	if e = writeJSONFresh(*output, bundle); e != nil {
		return e
	}
	if e = json.NewEncoder(os.Stdout).Encode(map[string]any{"qualification": "UNKNOWN", "replay": verdict, "conformance": result.Conformance, "execution": result.Execution, "report": *output, "cleanup": result.Cleanup}); e != nil {
		return e
	}
	if !exact {
		return fmt.Errorf("ReplayMismatch")
	}
	return nil
}
