package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestShenParser(t *testing.T) {
	v, err := parseShen(`[sample [node 2 dispatch] value 0 [[emit 2 "label" [int -7]]]]`)
	if err != nil {
		t.Fatal(err)
	}
	row, err := normalizeSample(v, 0)
	if err != nil {
		t.Fatal(err)
	}
	if row["depth"] != "0" {
		t.Fatal(row)
	}
	for _, s := range []string{"[", "]", "[] extra", `["unfinished]`} {
		if _, err := parseShen(s); err == nil {
			t.Errorf("admitted %q", s)
		}
	}
	for _, s := range []string{"[sample [node bad dispatch] value 0 []]", "[sample [node 2 unknown] value 0 []]", "[sample [node 2 dispatch] value -1 []]"} {
		v, e := parseShen(s)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = normalizeSample(v, 0); e == nil {
			t.Errorf("admitted %s", s)
		}
	}
}

func TestIndependentShenHand(t *testing.T) {
	executable := os.Getenv("FENRIR_SHEN_EXECUTABLE")
	if executable == "" {
		t.Skip("explicit Shen executable required for live model transport")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(root, "fixtures/tc0/left-trap-program.json"))
	if err != nil {
		t.Fatal(err)
	}
	var artifact map[string]any
	if err = json.Unmarshal(b, &artifact); err != nil {
		t.Fatal(err)
	}
	r, err := reference(root, executable, artifact, []any{"unit"}, 200)
	if err != nil {
		t.Fatal(err)
	}
	b, err = os.ReadFile(filepath.Join(root, "fixtures/tc0/left-trap-trace.json"))
	if err != nil {
		t.Fatal(err)
	}
	var hand struct {
		Steps   []map[string]any `json:"steps"`
		Outcome any              `json:"expected_outcome"`
	}
	if err = json.Unmarshal(b, &hand); err != nil {
		t.Fatal(err)
	}
	if r.Execution != "Completed" || !reflect.DeepEqual(r.Steps, hand.Steps) || !reflect.DeepEqual(r.Outcome, hand.Outcome) {
		t.Fatalf("independent Shen differs: %+v", r)
	}
	r, err = reference(root, executable, artifact, []any{"unit"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if r.Execution != "BudgetExhausted" || len(r.Steps) != 0 {
		t.Fatalf("zero fuel: %+v", r)
	}
	r, err = reference(root, executable, artifact, []any{"unit"}, 11)
	if err != nil {
		t.Fatal(err)
	}
	if r.Execution != "Completed" || len(r.Steps) != 11 {
		t.Fatalf("last step: %+v", r)
	}
}
