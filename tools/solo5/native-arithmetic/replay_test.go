package main

import (
	"encoding/json"
	"testing"
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
func TestStrictTape(t *testing.T) {
	data := map[string]any{"artifact_sha256": "a", "input_sha256": "b"}
	model := referenceResult{Steps: []map[string]any{}, Execution: "Completed"}
	rows, replies := expectations(data, model, "normal")
	r := sessionResult{Trace: rows, Choices: []map[string]any{replies[0], replies[1]}, Execution: "Completed", Conformance: "Admitted", Exit: "0", Cleanup: "confirmed"}
	if e := validateTape(data, model, "normal", r); e != nil {
		t.Fatal(e)
	}
	for _, kind := range []string{"missing", "extra", "reordered", "wrongmode", "badterminal", "incomplete"} {
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
			}
			if validateTape(data, model, "normal", c) == nil {
				t.Fatal("invalid tape admitted")
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
	r := sessionResult{Trace: []map[string]any{rows[0], observed}, Choices: []map[string]any{replies[0]}, Execution: "StoppedAtDivergence", Conformance: "Diverged", Cleanup: "confirmed", FirstError: map[string]any{"kind": "RecordMismatch", "record_index": "1", "epoch": "0", "expected": rows[1], "observed": observed}}
	if e := validateTape(data, model, "mutant", r); e != nil {
		t.Fatal(e)
	}
	r.Choices = append(r.Choices, replies[1])
	if validateTape(data, model, "mutant", r) == nil {
		t.Fatal("Run after divergence admitted")
	}
}
