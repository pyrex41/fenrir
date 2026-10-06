package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"time"
)

func snapshot(paths []string) (map[string]string, error) {
	m := map[string]string{}
	for _, p := range paths {
		a, e := filepath.EvalSymlinks(p)
		if e != nil {
			return nil, e
		}
		h, e := digest(a)
		if e != nil {
			return nil, e
		}
		m[a] = h
	}
	return m, nil
}
func sessionCLI(args []string) error {
	return sessionCLIContext(context.Background(), args)
}

func sessionCLIContext(ctx context.Context, args []string) error {
	f := flag.NewFlagSet("session", flag.ContinueOnError)
	root := f.String("root", ".", "repository root")
	build := f.String("build-report", "", "native build report")
	artifact := f.String("artifact", "", "closed artifact")
	input := f.String("input", "", "input JSON")
	shen := f.String("shen-executable", "", "independent Shen executable")
	output := f.String("output", "", "fresh local JSON report")
	mode := f.String("mode", "normal", "normal or mutant")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *build == "" || *artifact == "" || *input == "" || *shen == "" || *output == "" {
		return fmt.Errorf("required session flags missing or extra arguments")
	}
	if *mode != "normal" && *mode != "mutant" {
		return fmt.Errorf("CandidateMode")
	}
	for _, p := range []*string{root, build, artifact, input, shen, output} {
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
		return fmt.Errorf("OutputOutsideBuild")
	}
	if _, e = os.Lstat(*output); !os.IsNotExist(e) {
		return fmt.Errorf("FreshOutputRequired")
	}
	report, data, e := admitNative(*root, *build, *artifact, *input)
	if e != nil {
		return e
	}
	fuel, e := parseBuildFuel(report.Fuel)
	if e != nil {
		return e
	}
	files, e := requiredSessionFiles(*root, *build, *artifact, *input, *shen)
	if e != nil {
		return e
	}
	before, e := snapshot(files)
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
	result, e := runSessionContext(ctx, *root, report, data, model, filepath.Join(filepath.Dir(*build), "guest.spt"), *mode, 30*time.Second, nil)
	if e != nil {
		return e
	}
	after, e := snapshot(files)
	if e != nil {
		return e
	}
	if !reflect.DeepEqual(before, after) {
		return fmt.Errorf("SourceEvaluatorIdentityDrift")
	}
	if _, _, e = admitNative(*root, *build, *artifact, *input); e != nil {
		return e
	}
	bundle := map[string]any{"schema": "fenrir.solo5.native-arithmetic-development/1", "qualification": "UNKNOWN", "sources": before, "build_sha256": before[*build], "model": model, "result": result}
	if e = writeJSONFresh(*output, bundle); e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"qualification": "UNKNOWN", "execution": result.Execution, "conformance": result.Conformance, "first_error": result.FirstError, "report": *output, "cleanup": result.Cleanup})
}
