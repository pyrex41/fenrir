package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestResponseMapping(t *testing.T) {
	data := map[string]any{"artifact_sha256": "a", "input_sha256": "b"}
	sample := map[string]any{"epoch": "0", "site": map[string]any{"node": "2", "rule": "Dispatch"}, "after": "Value", "depth": "0", "events": []any{}}
	rows, replies := expectations(data, referenceResult{Steps: []map[string]any{sample}, Execution: "Completed"}, "normal")
	kinds := []string{}
	for i, r := range rows {
		kinds = append(kinds, r["kind"].(string))
		if r["sequence"] != []string{"0", "1", "2", "3"}[i] || r["epoch"] != []string{"0", "0", "0", "1"}[i] {
			t.Fatal(rows)
		}
	}
	if !reflect.DeepEqual(kinds, []string{"Hello", "Boundary", "Sample", "Terminal"}) {
		t.Fatal(kinds)
	}
	if len(replies) != 3 || replies[0]["kind"] != "Init" || replies[1]["kind"] != "Run" || replies[3]["kind"] != "Ack" {
		t.Fatal(replies)
	}
	if rows[1]["domain_hash"] != "2cfd3c3d4c44e71ac259b85423ce0f53572e74026e3aad3c75d18206e4357558" {
		t.Fatal(rows[1])
	}
}
func TestZeroFuelNoRun(t *testing.T) {
	rows, replies := expectations(map[string]any{}, referenceResult{Execution: "BudgetExhausted"}, "normal")
	if len(rows) != 2 || len(replies) != 2 || replies[0]["kind"] != "Init" || replies[1]["kind"] != "Ack" || rows[1]["execution"] != "BudgetExhausted" {
		t.Fatal(rows, replies)
	}
}
func TestInvalidModeBeforeLaunch(t *testing.T) {
	if _, e := runSession("/unused", buildReport{}, nil, referenceResult{}, "/unused", "wrong", time.Second); e == nil {
		t.Fatal("invalid mode launched")
	}
}
func TestIncompleteAdmissionBeforeNodeOrDocker(t *testing.T) {
	root := t.TempDir()
	p := filepath.Join(root, "build.json")
	r := buildReport{Schema: "fenrir.solo5.native-arithmetic-build/1", Qualification: "UNKNOWN", Profile: profile, Cleanup: "confirmed", Equal: true, Before: map[string]string{}, After: map[string]string{}}
	if e := writeJSONFresh(p, r); e != nil {
		t.Fatal(e)
	}
	if _, _, e := admitNative(root, p, "/missing-artifact", "/missing-input"); e == nil || e.Error() != "MissingBuildInputPaths" {
		t.Fatalf("%v", e)
	}
}
func TestSourceSetCompleteness(t *testing.T) {
	root := t.TempDir()
	paths := []string{"tools/solo5/native-arithmetic/main.go", "tools/solo5/native-arithmetic/go.mod", "backends/solo5/native-arithmetic/machine.h", "backends/solo5/native-arithmetic/machine.c", "backends/solo5/native-arithmetic/format.h", "backends/solo5/native-arithmetic/format.c", "backends/solo5/native-arithmetic/guest.c", "backends/solo5/protocol.h", "backends/solo5/protocol.c", "tools/solo5/native-arithmetic/lower.mjs", "tools/solo5/native-arithmetic/admit.mjs", "tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs", "build/solo5/data.h", "build/solo5/dependency.json"}
	abs := []string{}
	for _, p := range paths {
		a := filepath.Join(root, p)
		if e := os.MkdirAll(filepath.Dir(a), 0755); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(a, []byte(p), 0644); e != nil {
			t.Fatal(e)
		}
		abs = append(abs, a)
	}
	m, e := sourceHashes(root, abs)
	if e != nil {
		t.Fatal(e)
	}
	r := buildReport{Before: m, After: m, DataPath: "build/solo5/data.h", DependencyPath: "build/solo5/dependency.json", Data: m["build/solo5/data.h"], Dependency: m["build/solo5/dependency.json"]}
	if e = verifyBuildSources(root, r); e != nil {
		t.Fatal(e)
	}
	delete(m, "backends/solo5/native-arithmetic/machine.c")
	if verifyBuildSources(root, r) == nil {
		t.Fatal("omitted candidate source admitted")
	}
	m, e = sourceHashes(root, abs)
	if e != nil {
		t.Fatal(e)
	}
	r.Before = m
	r.After = m
	os.WriteFile(filepath.Join(root, "tools/solo5/native-arithmetic/extra.go"), []byte("new source"), 0644)
	if verifyBuildSources(root, r) == nil {
		t.Fatal("added Go file admitted")
	}
}
