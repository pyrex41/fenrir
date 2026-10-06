package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const outputLimit = 1048576

type outputBudget struct {
	mu   sync.Mutex
	used int
}

type boundedBuffer struct {
	mu       sync.Mutex
	b        bytes.Buffer
	exceeded bool
	budget   *outputBudget
}

func newOutputBuffers() (*boundedBuffer, *boundedBuffer) {
	budget := &outputBudget{}
	return &boundedBuffer{budget: budget}, &boundedBuffer{budget: budget}
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.budget != nil {
		b.budget.mu.Lock()
		defer b.budget.mu.Unlock()
		if len(p) > outputLimit-b.budget.used {
			b.exceeded = true
			return 0, fmt.Errorf("OutputLimit")
		}
		b.budget.used += len(p)
	} else if len(p) > outputLimit-b.b.Len() {
		b.exceeded = true
		return 0, fmt.Errorf("OutputLimit")
	}
	return b.b.Write(p)
}
func (b *boundedBuffer) snapshot() (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String(), b.exceeded
}

type commandResult struct {
	Stdout string
	Stderr string
	Exit   int
}

// Every child owns a process group. Kill and join even after a successful exit:
// grandchildren must not survive. This is lifetime ownership, not OS isolation.
func synchronous(root string, argv []string, timeout time.Duration) (commandResult, error) {
	return runOwnedCommand(root, argv, timeout, true)
}

// The inspection leaf must not recursively inspect its own process group.
// It still has bounded combined output, a watchdog, group kill and joined IO.
func runOwnedCommand(root string, argv []string, timeout time.Duration, inspectAfter bool) (commandResult, error) {
	return runOwnedCommandCapture(root, argv, timeout, inspectAfter, nil)
}

func runOwnedCommandCapture(root string, argv []string, timeout time.Duration, inspectAfter bool, pgid *int) (commandResult, error) {
	var result commandResult
	if len(argv) == 0 {
		return result, fmt.Errorf("EmptyCommand")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	out, errout := newOutputBuffers()
	cmd.Stdout = out
	cmd.Stderr = errout
	if err := cmd.Start(); err != nil {
		return result, err
	}
	if pgid != nil {
		*pgid = cmd.Process.Pid
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	var runErr error
	select {
	case runErr = <-done:
	case <-timer.C:
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		runErr = fmt.Errorf("CommandTimeout")
	}
	killErr := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if killErr != nil && killErr != syscall.ESRCH {
		return result, fmt.Errorf("ProcessGroupCleanup: %w", killErr)
	}
	result.Exit = cmd.ProcessState.ExitCode()
	var outLimit, errLimit bool
	result.Stdout, outLimit = out.snapshot()
	result.Stderr, errLimit = errout.snapshot()
	if inspectAfter {
		if err := confirmGroupAbsent(cmd.Process.Pid); err != nil {
			return result, err
		}
	}
	if outLimit || errLimit {
		return result, fmt.Errorf("OutputLimit")
	}
	return result, runErr
}

func confirmGroupAbsent(pgid int) error {
	r, err := runOwnedCommand("", []string{"ps", "-axo", "pid=,pgid=,stat="}, 5*time.Second, false)
	if err != nil {
		return inspectionFailure(pgid, r, fmt.Sprintf("CleanupInspection: %v", err), "")
	}
	rows := 0
	for _, line := range strings.Split(r.Stdout, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) != 3 {
			return inspectionFailure(pgid, r, "CleanupInspectionShape", line)
		}
		pid, pe := strconv.Atoi(f[0])
		group, ge := strconv.Atoi(f[1])
		if pe != nil || ge != nil || pid <= 0 || group < 0 || !strings.ContainsAny(f[2][:1], "RSDTtWXZUIP") {
			return inspectionFailure(pgid, r, "CleanupInspectionShape", line)
		}
		rows++
		if group == pgid && !strings.HasPrefix(f[2], "Z") {
			return inspectionFailure(pgid, r, "ProcessGroupCleanupUnresolved", line)
		}
	}
	if rows == 0 {
		return inspectionFailure(pgid, r, "CleanupInspectionEmpty", "")
	}
	return nil
}
