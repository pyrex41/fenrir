package main

import (
	"errors"
	"fmt"
	"path/filepath"
)

// Bounded command output was captured by runOwnedCommand. Diagnostics preserve
// evidence, never establish absence or relax a failed inspection.
type cleanupInspectionError struct {
	Reason       string        `json:"reason"`
	TargetPGID   int           `json:"target_pgid"`
	Command      []string      `json:"inspection_command"`
	Result       commandResult `json:"inspection_result"`
	OffendingRow string        `json:"offending_row"`
}

func (e *cleanupInspectionError) Error() string { return e.Reason }
func inspectionFailure(pgid int, r commandResult, reason, row string) error {
	return &cleanupInspectionError{Reason: reason, TargetPGID: pgid, Command: []string{"ps", "-axo", "pid=,pgid=,stat="}, Result: r, OffendingRow: row}
}

type ownedFailureDiagnostic struct {
	Schema            string                  `json:"schema"`
	Stage             string                  `json:"stage"`
	Container         string                  `json:"container"`
	Owner             string                  `json:"owner"`
	PGID              int                     `json:"pgid"`
	Command           []string                `json:"command"`
	FirstError        string                  `json:"first_error"`
	CleanupError      string                  `json:"cleanup_error"`
	Inspection        *cleanupInspectionError `json:"inspection"`
	CleanupInspection *cleanupInspectionError `json:"cleanup_inspection"`
	Cleanup           string                  `json:"cleanup"`
}

func persistOwnedFailure(dir, id, stage, name, owner string, argv []string, pgid int, primary, cleanup error) error {
	if primary == nil && cleanup == nil {
		return nil
	}
	d := ownedFailureDiagnostic{Schema: "fenrir.solo5.owned-failure-diagnostic/1", Stage: stage, Container: name, Owner: owner, PGID: pgid, Command: argv, Cleanup: "unresolved"}
	if primary != nil {
		d.FirstError = primary.Error()
		errors.As(primary, &d.Inspection)
	}
	if cleanup != nil {
		d.CleanupError = cleanup.Error()
		errors.As(cleanup, &d.CleanupInspection)
	}
	path := filepath.Join(dir, "owned-failure-"+id+".json")
	if e := writeJSONFresh(path, d); e != nil {
		return fmt.Errorf("OwnedFailureDiagnosticWrite: %w", e)
	}
	return nil
}
