package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func copyResult(t *testing.T, r sessionResult) sessionResult {
	t.Helper()
	b, e := json.Marshal(r)
	if e != nil {
		t.Fatal(e)
	}
	var c sessionResult
	if e = json.Unmarshal(b, &c); e != nil {
		t.Fatal(e)
	}
	return c
}
func tapeCommand(mode string) []string {
	return append(dockerArgs("fenrir-solo5-native-0123456789abcdef", "0123456789abcdef0123456789abcdef", "sha256:"+strings.Repeat("a", 64), []mount{{"/sealed/guest.spt", "/guest/guest.spt"}}, false, true), "/opt/fenrir/solo5-spt-control", "--mem=16", "--fenrir-control-stdin", "/guest/guest.spt", "--solo5:quiet", mode)
}

func TestStrictTape(t *testing.T) {
	data := map[string]any{"artifact_sha256": "a", "input_sha256": "b"}
	model := referenceResult{Steps: []map[string]any{}, Execution: "Completed"}
	rows, replies := expectations(data, model, "normal")
	r := sessionResult{Trace: rows, Choices: []map[string]any{replies[0], replies[1]}, Execution: "Completed", Conformance: "Admitted", Exit: "0", Cleanup: "confirmed", Command: tapeCommand("normal")}
	if e := validateTape(data, model, "normal", r); e != nil {
		t.Fatal(e)
	}
	for _, kind := range []string{"missing", "extra", "reordered", "wrongmode", "badterminal", "incomplete", "command mode", "command memory", "command executable", "command prefix", "command owner", "command absent", "command suffix"} {
		t.Run(kind, func(t *testing.T) {
			c := copyResult(t, r)
			switch kind {
			case "missing":
				c.Choices = c.Choices[:1]
			case "extra":
				c.Choices = append(c.Choices, c.Choices[0])
			case "reordered":
				c.Choices[0], c.Choices[1] = c.Choices[1], c.Choices[0]
			case "wrongmode":
				c.Choices[0]["mode"] = "mutant"
			case "badterminal":
				c.Trace[1]["execution"] = "BudgetExhausted"
			case "incomplete":
				c.Execution = "HarnessTimeout"
			case "command mode":
				c.Command[len(c.Command)-1] = "mutant"
			case "command memory":
				c.Command[len(c.Command)-5] = "--mem=32"
			case "command executable":
				c.Command[len(c.Command)-6] = "wrong"
			case "command prefix":
				c.Command[0] = "wrong"
			case "command owner":
				c.Command[5] = "org.fenrir.probe.owner=unknown"
			case "command absent":
				c.Command = nil
			case "command suffix":
				c.Command = append(c.Command, "extra")
			}
			if validateTape(data, model, "normal", c) == nil {
				t.Fatal("invalid tape admitted")
			}
		})
	}
}
func TestReplayLaunchInputsBeforeExecution(t *testing.T) {
	// No executable is available: these are no-launch unit vectors, not Docker evidence.
	t.Setenv("PATH", t.TempDir())
	data := map[string]any{"artifact_sha256": "a", "input_sha256": "b"}
	model := referenceResult{Steps: []map[string]any{}, Execution: "Completed"}
	rows, replies := expectations(data, model, "normal")
	r := sessionResult{Trace: rows, Choices: []map[string]any{replies[0], replies[1]}, Execution: "Completed", Conformance: "Admitted", Exit: "0", Cleanup: "confirmed", Command: tapeCommand("normal")}
	for _, kind := range []string{"image", "guest path"} {
		t.Run(kind, func(t *testing.T) {
			c := copyResult(t, r)
			if kind == "image" {
				c.Command[22] = "sha256:" + strings.Repeat("b", 64)
			} else {
				c.Command[21] = "type=bind,src=/swapped/guest.spt,dst=/guest/guest.spt,readonly"
			}
			if e := validateTape(data, model, "normal", c); e != nil {
				t.Fatalf("shape should be valid: %v", e)
			}
			_, e := runSessionTape(t.TempDir(), buildReport{Image: r.Command[22]}, data, model, "/sealed/guest.spt", "normal", time.Second, &c)
			if e == nil || e.Error() != "ReplayLaunchIdentity" {
				t.Fatalf("launch identity not rejected before execution: %v", e)
			}
		})
	}
}

func TestDivergenceTape(t *testing.T) {
	data := map[string]any{"artifact_sha256": "a", "input_sha256": "b"}
	model := referenceResult{Steps: []map[string]any{{"epoch": "0", "site": map[string]any{"node": "2", "rule": "Dispatch"}}}, Execution: "Completed"}
	rows, replies := expectations(data, model, "mutant")
	observed := clone(rows[1], "Boundary")
	observed["site"] = map[string]any{"node": "6", "rule": "Dispatch"}
	r := sessionResult{Trace: []map[string]any{rows[0], observed}, Choices: []map[string]any{replies[0]}, Execution: "StoppedAtDivergence", Conformance: "Diverged", Cleanup: "confirmed", Command: tapeCommand("mutant"), FirstError: map[string]any{"kind": "RecordMismatch", "record_index": "1", "epoch": "0", "expected": rows[1], "observed": observed}}
	if e := validateTape(data, model, "mutant", r); e != nil {
		t.Fatal(e)
	}
	r.Choices = append(r.Choices, replies[1])
	if validateTape(data, model, "mutant", r) == nil {
		t.Fatal("Run after divergence admitted")
	}
}
