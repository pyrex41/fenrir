package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCleanupDiagnosticPreservesRejectedRow(t *testing.T) {
	dir := t.TempDir()
	body := "123 456 ?"
	if e := os.WriteFile(filepath.Join(dir, "ps"), []byte("#!/bin/sh\nprintf '%s\\n' '"+body+"'\nprintf '%s' 'inspection note' >&2\n"), 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("PATH", dir)
	err := confirmGroupAbsent(999999)
	var detail *cleanupInspectionError
	if !errors.As(err, &detail) {
		t.Fatalf("lost typed inspection: %v", err)
	}
	if detail.Reason != "CleanupInspectionShape" || detail.TargetPGID != 999999 || detail.OffendingRow != body || detail.Result.Stdout != body+"\n" || detail.Result.Stderr != "inspection note" || detail.Result.Exit != 0 {
		t.Fatalf("lost first evidence: %+v", detail)
	}
	wrapped := fmt.Errorf("DockerInspect: %w", err)
	if e := persistOwnedFailure(dir, "test", "isolated-build", "exact-container", "exact-owner", []string{"docker", "run"}, 1234, wrapped, nil); e != nil {
		t.Fatal(e)
	}
	var saved ownedFailureDiagnostic
	if e := loadJSON(filepath.Join(dir, "owned-failure-test.json"), &saved); e != nil {
		t.Fatal(e)
	}
	if saved.PGID != 1234 || saved.Container != "exact-container" || saved.Owner != "exact-owner" || saved.Inspection == nil || saved.Inspection.OffendingRow != body || saved.Cleanup != "unresolved" {
		t.Fatalf("diagnostic lost ownership: %+v", saved)
	}
	// A second error cannot erase the original; fresh output cannot be reused.
	if persistOwnedFailure(dir, "test", "isolated-build", "x", "y", nil, 0, wrapped, errors.New("remove failed")) == nil {
		t.Fatal("overwrote retained failure")
	}
	if e := persistOwnedFailure(dir, "both", "isolated-build", "exact-container", "exact-owner", nil, 1234, wrapped, errors.New("remove failed")); e != nil {
		t.Fatal(e)
	}
	if e := loadJSON(filepath.Join(dir, "owned-failure-both.json"), &saved); e != nil {
		t.Fatal(e)
	}
	if saved.Inspection == nil || saved.FirstError == "" || saved.CleanupError != "remove failed" {
		t.Fatal("first error overwritten")
	}
}

// Explicit read-only investigation, not guest execution or historical cleanup
// closure. No remove/run/build commands, retries or manufactured daemon faults.
func TestReadOnlyCleanupInvestigation(t *testing.T) {
	dir := os.Getenv("FENRIR_CLEANUP_INVESTIGATION_DIR")
	if dir == "" {
		t.Skip("explicit investigation output required")
	}
	commands := [][]string{
		{"/bin/ps", "-axo", "pid=,pgid=,stat="},
		{"docker", "ps", "-a", "--filter", "name=fenrir-solo5-native-", "--format", "{{.ID}} {{.Names}} {{.Status}} {{.Labels}}"},
	}
	for i, argv := range commands {
		var pgid int
		r, e := runOwnedCommandCapture("", argv, 15*time.Second, false, &pgid)
		report := struct {
			Schema            string        `json:"schema"`
			HistoricalCleanup string        `json:"historical_cleanup"`
			Command           []string      `json:"command"`
			ObserverPGID      int           `json:"observer_pgid"`
			Result            commandResult `json:"result"`
			Error             string        `json:"error"`
		}{Schema: "fenrir.solo5.cleanup-readonly-investigation/1", HistoricalCleanup: "UNRESOLVED", Command: argv, ObserverPGID: pgid, Result: r}
		if e != nil {
			report.Error = e.Error()
		}
		if we := writeJSONFresh(filepath.Join(dir, fmt.Sprintf("read-only-%d.json", i)), report); we != nil {
			t.Fatal(we)
		}
		if e != nil {
			t.Fatalf("read-only observation failed (retained): %v", e)
		}
	}
}
