package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Fault injection for inspection only; not live Docker or guest evidence.
func TestCleanupInspectionRejectsFlood(t *testing.T) {
	dir := t.TempDir()
	ps := filepath.Join(dir, "ps")
	// Finite, foreground shell builtin output; no descendant candidate process.
	script := "#!/bin/sh\ni=0\nwhile [ $i -lt 40000 ]; do printf '123 456 S padding-padding-padding-padding\\n'; i=$((i+1)); done\n"
	if e := os.WriteFile(ps, []byte(script), 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("PATH", dir)
	e := confirmGroupAbsent(999999)
	if e == nil || !strings.Contains(e.Error(), "OutputLimit") {
		t.Fatalf("expected bounded unresolved inspection, got %v", e)
	}
}

func TestCleanupInspectionRejectsMalformed(t *testing.T) {
	for name, output := range map[string]string{"empty": "", "garbage": "daemon unavailable", "pid": "word 123 S", "pgid": "123 word S", "state": "123 456 ?"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			if e := os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/bin/sh\nprintf '%s\\n' '"+output+"'\n"), 0700); e != nil {
				t.Fatal(e)
			}
			t.Setenv("PATH", dir)
			target := 999999
			if name == "state" {
				target = 456
			} // Unknown owned state remains unresolved.
			if e := confirmGroupAbsent(target); e == nil {
				t.Fatal("malformed identity or unknown owned state proved absence")
			}
		})
	}
}

func TestHostJSONRequiresRegularFile(t *testing.T) {
	_, e := readHostJSON(t.TempDir())
	if e == nil || !strings.Contains(e.Error(), "HostJSONRegularFileRequired") {
		t.Fatalf("nonregular file must reject before reading, got %v", e)
	}
}
