package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"testing"
	"time"
)

type ownershipGroupReview struct {
	PGID         int           `json:"pgid"`
	SignalZero   string        `json:"signal_zero"`
	ObserverPGID int           `json:"observer_pgid"`
	Snapshot     commandResult `json:"snapshot"`
	Error        string        `json:"error"`
}
type ownershipReview struct {
	Schema              string                 `json:"schema"`
	Scope               string                 `json:"scope"`
	OriginalFailureHash string                 `json:"original_failure_sha256"`
	OriginalExecution   string                 `json:"original_execution"`
	Qualification       string                 `json:"qualification"`
	CurrentResources    string                 `json:"current_resources"`
	Container           string                 `json:"container"`
	Owner               string                 `json:"owner"`
	Groups              []ownershipGroupReview `json:"groups"`
	InspectObserverPGID int                    `json:"inspect_observer_pgid"`
	Inspect             commandResult          `json:"inspect"`
	InspectError        string                 `json:"inspect_error"`
	Error               string                 `json:"first_error"`
}

// Explicitly authorized current-resource review only. Signal 0 does not send a
// signal. All external commands are read-only; there is no rm/run/build/retry.
// Later absence does NOT rewrite the original failure or admit its execution.
func TestReadOnlyExactOwnershipReview(t *testing.T) {
	input, out := os.Getenv("FENRIR_OWNERSHIP_FAILURE_REPORT"), os.Getenv("FENRIR_OWNERSHIP_REVIEW_DIR")
	if input == "" || out == "" {
		t.Skip("explicit exact-failure report and fresh review output required")
	}
	var d ownedFailureDiagnostic
	if e := loadJSON(input, &d); e != nil {
		t.Fatal(e)
	}
	if d.Schema != "fenrir.solo5.owned-failure-diagnostic/1" || d.Stage != "session" || d.PGID <= 0 || d.CleanupInspection == nil || d.CleanupInspection.TargetPGID <= 0 || !regexp.MustCompile(`^fenrir-solo5-native-[a-f0-9]{16}$`).MatchString(d.Container) || !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(d.Owner) {
		t.Fatal("exact ownership evidence required")
	}
	hash, e := digest(input)
	if e != nil {
		t.Fatal(e)
	}
	r := ownershipReview{Schema: "fenrir.solo5.current-exact-ownership-review/1", Scope: "current resources only; no historical execution promotion", OriginalFailureHash: hash, OriginalExecution: "FAILED-UNCHANGED", Qualification: "UNKNOWN", CurrentResources: "UNRESOLVED", Container: d.Container, Owner: d.Owner, Groups: []ownershipGroupReview{}}
	var reviewErr error
	defer func() {
		after, e := digest(input)
		if e != nil || after != hash {
			reviewErr = fmt.Errorf("original diagnostic changed during review")
		}
		if reviewErr != nil {
			r.Error = reviewErr.Error()
		}
		if e := writeJSONFresh(filepath.Join(out, "exact-ownership-review.json"), r); e != nil {
			t.Error(e)
		}
		if reviewErr != nil {
			t.Error(reviewErr)
		}
	}()
	seen := map[int]bool{}
	for _, pgid := range []int{d.PGID, d.CleanupInspection.TargetPGID} {
		if seen[pgid] {
			continue
		}
		seen[pgid] = true
		g := ownershipGroupReview{PGID: pgid}
		zero := syscall.Kill(-pgid, 0)
		if zero == syscall.ESRCH {
			g.SignalZero = "ESRCH"
		} else {
			g.SignalZero = fmt.Sprintf("%v", zero)
			g.Error = "owned group absence not established"
			r.Groups = append(r.Groups, g)
			reviewErr = fmt.Errorf("owned group %d absence unresolved: %v", pgid, zero)
			return
		}
		snapshot, e := runOwnedCommandCapture("", []string{"/bin/ps", "-axo", "pid=,pgid=,stat="}, 5*time.Second, false, &g.ObserverPGID)
		g.Snapshot = snapshot
		if e == nil {
			e = checkGroupSnapshot(pgid, snapshot)
		}
		if e == nil && syscall.Kill(-g.ObserverPGID, 0) != syscall.ESRCH {
			e = fmt.Errorf("review observer group absence unresolved")
		}
		if e != nil {
			g.Error = e.Error()
		}
		r.Groups = append(r.Groups, g)
		if e != nil {
			reviewErr = e
			return
		}
	}
	result, inspectErr := runOwnedCommandCapture("", []string{"docker", "inspect", d.Container}, 15*time.Second, true, &r.InspectObserverPGID)
	r.Inspect = result
	if inspectErr != nil {
		r.InspectError = inspectErr.Error()
	}
	if e := validateContainerAbsence(d.Container, result, inspectErr); e != nil {
		reviewErr = e
		return
	}
	if syscall.Kill(-r.InspectObserverPGID, 0) != syscall.ESRCH {
		reviewErr = fmt.Errorf("inspect observer group absence unresolved")
		return
	}
	r.CurrentResources = "ABSENCE_CONFIRMED_AT_REVIEW"
}
