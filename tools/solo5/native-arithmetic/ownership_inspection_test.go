package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// Recorded live distinguishing row, exercised through a fake ps executable.
// This is parser evidence, not a live resource-absence receipt.
func TestOwnershipScopedInspection(t *testing.T) {
	for _, tc := range []struct {
		name, row string
		target    int
		accept    bool
		reason    string
	}{
		{"recorded unrelated exiting", "31115 31112 ?E", 31113, true, ""},
		{"unknown unrelated", "123 456 ?", 999999, true, ""},
		{"unknown owned", "31115 31112 ?E", 31112, false, "ProcessGroupCleanupUnresolved"},
		{"live owned", "31115 31112 S", 31112, false, "ProcessGroupCleanupUnresolved"},
		{"dead owned", "31115 31112 Z", 31112, true, ""},
		{"dead owned known modifier", "31115 31112 Zs+", 31112, true, ""},
		{"unknown zombie modifier", "31115 31112 Z?", 31112, false, "ProcessGroupCleanupUnresolved"},
		{"ambiguous unrelated identity", "word 31112 ?E", 31113, false, "CleanupInspectionShape"},
		{"ambiguous owned identity", "31115 word ?E", 31112, false, "CleanupInspectionShape"},
		{"negative group", "31115 -1 ?E", 31113, false, "CleanupInspectionShape"},
		{"missing field", "31115 31112", 31113, false, "CleanupInspectionShape"},
		{"invalid target", "31115 31112 S", 0, false, "InvalidOwnedProcessGroup"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if e := os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/bin/sh\nprintf '%s\\n' '"+tc.row+"'\n"), 0700); e != nil {
				t.Fatal(e)
			}
			t.Setenv("PATH", dir)
			e := confirmGroupAbsent(tc.target)
			if tc.accept {
				if e != nil {
					t.Fatalf("unrelated state/dead owned row cannot establish live ownership: %v", e)
				}
				return
			}
			var d *cleanupInspectionError
			if !errors.As(e, &d) || d.Reason != tc.reason || d.TargetPGID != tc.target {
				t.Fatalf("expected retained rejection %s, got %v", tc.reason, e)
			}
		})
	}
}
