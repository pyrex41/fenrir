package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"syscall"
	"time"
)

func common(data map[string]any, mode, kind string, sequence, epoch int) map[string]any {
	return map[string]any{"artifact_sha256": data["artifact_sha256"], "input_sha256": data["input_sha256"], "epoch": strconv.Itoa(epoch), "kind": kind, "mode": mode, "profile": profile, "run_id": "native-0", "sequence": strconv.Itoa(sequence)}
}
func clone(row map[string]any, kind string) map[string]any {
	r := map[string]any{}
	for k, v := range row {
		r[k] = v
	}
	r["kind"] = kind
	return r
}
func expectations(data map[string]any, model referenceResult, mode string) ([]map[string]any, map[int]map[string]any) {
	rows := []map[string]any{common(data, mode, "Hello", 0, 0)}
	replies := map[int]map[string]any{0: clone(rows[0], "Init")}
	domain, _ := canonical([]any{[]any{"Run", "0"}})
	for i, s := range model.Steps {
		r := common(data, mode, "Boundary", 2*i+1, i)
		r["domain_hash"] = hashBytes(domain)
		r["site"] = s["site"]
		replies[len(rows)] = clone(r, "Run")
		rows = append(rows, r)
		r = common(data, mode, "Sample", 2*i+2, i)
		r["sample"] = s
		rows = append(rows, r)
	}
	r := common(data, mode, "Terminal", 2*len(model.Steps)+1, len(model.Steps))
	r["execution"] = model.Execution
	replies[len(rows)] = clone(r, "Ack")
	rows = append(rows, r)
	return rows, replies
}

type sessionResult struct {
	Execution   string           `json:"execution"`
	Conformance string           `json:"conformance"`
	Exit        string           `json:"exit"`
	Trace       []map[string]any `json:"trace"`
	Choices     []map[string]any `json:"choices"`
	FirstError  map[string]any   `json:"first_error"`
	StdoutHash  string           `json:"stdout_sha256"`
	Stderr      string           `json:"stderr"`
	Cleanup     string           `json:"cleanup"`
	Command     []string         `json:"command"`
}
type recordEvent struct {
	Row map[string]any
	Err error
}

func runSession(root string, report buildReport, data map[string]any, model referenceResult, binary, mode string, timeout time.Duration) (sessionResult, error) {
	return runSessionTape(root, report, data, model, binary, mode, timeout, nil)
}
func runSessionTape(root string, report buildReport, data map[string]any, model referenceResult, binary, mode string, timeout time.Duration, tape *sessionResult) (sessionResult, error) {
	return runSessionContext(context.Background(), root, report, data, model, binary, mode, timeout, tape)
}

func sessionStop(ctx context.Context) string {
	if ctx.Err() == context.Canceled {
		return "HarnessCanceled"
	}
	return "HarnessTimeout"
}

func runSessionContext(parent context.Context, root string, report buildReport, data map[string]any, model referenceResult, binary, mode string, timeout time.Duration, tape *sessionResult) (result sessionResult, err error) {
	if timeout <= 0 || timeout > 30*time.Second || len(model.Steps) > 200 {
		return result, fmt.Errorf("SessionBounds")
	}
	if e := parent.Err(); e != nil {
		return result, e
	}
	if mode != "normal" && mode != "mutant" {
		return result, fmt.Errorf("CandidateMode")
	}
	expected, replies := expectations(data, model, mode)
	if tape != nil {
		if e := validateRecordedSessionLaunch(tape.Command, mode, report.Image, binary); e != nil {
			return result, e
		}
		if e := validateTape(data, model, mode, *tape); e != nil {
			return result, e
		}
	}
	id, e := token()
	if e != nil {
		return result, e
	}
	owner, e := token()
	if e != nil {
		return result, e
	}
	name := "fenrir-solo5-native-" + id[:16]
	mounts := []mount{{binary, "/guest/guest.spt"}}
	launch := []string{"/opt/fenrir/solo5-spt-control", "--mem=16", "--fenrir-control-stdin", "/guest/guest.spt", "--solo5:quiet", mode}
	argv := append(dockerArgs(name, owner, report.Image, mounts, false, true), launch...)
	result = sessionResult{Trace: []map[string]any{}, Choices: []map[string]any{}, Command: argv, Conformance: "Unknown"}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	// An explicit parent-owned pipe avoids Wait closing StdoutPipe while the
	// reader is still draining a completed process. Join reader on every path.
	read, write, e := os.Pipe()
	if e != nil {
		return result, e
	}
	defer read.Close()
	defer write.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	stdout, stderr := newOutputBuffers()
	cmd.Stdout = write
	cmd.Stderr = stderr
	input, e := cmd.StdinPipe()
	if e != nil {
		return result, e
	}
	defer input.Close()
	if e = cmd.Start(); e != nil {
		return result, e
	}
	write.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	records := make(chan recordEvent, 1)
	readerDone := make(chan struct{})
	readerCtx, readerCancel := context.WithCancel(context.Background())
	go func() {
		defer close(readerDone)
		r := bufio.NewReader(io.TeeReader(read, stdout))
		for {
			row, e := readFrame(r)
			select {
			case records <- recordEvent{row, e}:
			case <-readerCtx.Done():
				return
			}
			if e != nil {
				return
			}
		}
	}()
	waited := false
	var waitErr error
	defer func() {
		primary := err
		var cleanupFailure error
		defer func() {
			if e := persistOwnedFailure(filepath.Dir(binary), id, "session", name, owner, argv, cmd.Process.Pid, primary, cleanupFailure); e != nil {
				err = fmt.Errorf("%v; %w", err, e)
			}
		}()
		input.Close()
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if !waited {
			waitErr = <-done
			waited = true
		}
		readerCancel()
		read.Close()
		<-readerDone
		if e := removeContainer(root, name); e != nil {
			cleanupFailure = e
			err = e
			result.Cleanup = "unresolved"
			return
		}
		if e := confirmGroupAbsent(cmd.Process.Pid); e != nil {
			cleanupFailure = e
			err = e
			result.Cleanup = "unresolved"
			return
		}
		result.Cleanup = "confirmed"
	}()
	eof := false
	stopped := ""
	inputBytes := 0
loop:
	for !(eof && waited) {
		select {
		case <-ctx.Done():
			stopped = sessionStop(ctx)
			break loop
		case waitErr = <-done:
			waited = true
			done = nil
		case event := <-records:
			if event.Err != nil {
				if event.Err == io.EOF {
					eof = true
					records = nil
					continue
				}
				result.FirstError = map[string]any{"kind": event.Err.Error(), "record_index": strconv.Itoa(len(result.Trace))}
				stopped = "StoppedAtDivergence"
				break loop
			}
			index := len(result.Trace)
			result.Trace = append(result.Trace, event.Row)
			if index >= len(expected) || !reflect.DeepEqual(event.Row, expected[index]) {
				var want any
				if index < len(expected) {
					want = expected[index]
				}
				result.FirstError = map[string]any{"kind": "RecordMismatch", "record_index": strconv.Itoa(index), "epoch": event.Row["epoch"], "expected": want, "observed": event.Row}
				stopped = "StoppedAtDivergence"
				break loop
			}
			needed := 0
			if index > 0 {
				needed = 1 + index/2
			}
			if len(result.Choices) < needed {
				result.FirstError = map[string]any{"kind": "UnsolicitedProgress", "record_index": strconv.Itoa(index)}
				stopped = "StoppedAtDivergence"
				break loop
			}
			if reply, ok := replies[index]; ok {
				if tape != nil {
					if len(result.Choices) >= len(tape.Choices) {
						return result, fmt.Errorf("ReplayChoiceExhausted")
					}
					reply = tape.Choices[len(result.Choices)]
				}
				b, e := frame(reply)
				if e != nil {
					return result, e
				}
				if len(b) > outputLimit-inputBytes {
					result.FirstError = map[string]any{"kind": "InputLimit"}
					stopped = "HarnessError"
					break loop
				}
				inputBytes += len(b)
				// A blocked pipe cannot escape the session watchdog. Close and join the
				// sole writer before returning; no fire-and-forget IO goroutines.
				written := make(chan error, 1)
				go func() { _, e := input.Write(b); written <- e }()
				select {
				case e = <-written:
				case <-ctx.Done():
					input.Close()
					<-written
					stopped = sessionStop(ctx)
					break loop
				}
				if e != nil {
					result.FirstError = map[string]any{"kind": "InputWrite"}
					stopped = "HarnessError"
					break loop
				}
				result.Choices = append(result.Choices, reply)
				if reply["kind"] == "Ack" {
					input.Close()
				}
			}
		}
	}
	if stopped != "" {
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	if !waited {
		waitErr = <-done
		waited = true
	}
	// Freeze output only after joining the reader. On early stop the captured
	// prefix is explicitly incomplete; never race a deferred drain against hashes.
	readerCancel()
	read.Close()
	<-readerDone
	info, e := inspect(root, "inspect", name)
	if e != nil {
		return result, e
	}
	if info.Image != report.Image || info.Config.Labels["org.fenrir.probe.owner"] != owner {
		return result, fmt.Errorf("SessionContainerIdentity")
	}
	if e = checkPolicy(info, mounts, false, true, launch); e != nil {
		return result, e
	}
	result.Exit = strconv.Itoa(cmd.ProcessState.ExitCode())
	out, outLimit := stdout.snapshot()
	serr, errLimit := stderr.snapshot()
	result.StdoutHash = hashBytes([]byte(out))
	if len(serr) > 8192 {
		serr = serr[:8192]
	}
	result.Stderr = serr
	exit := cmd.ProcessState.ExitCode()
	switch {
	case outLimit || errLimit:
		result.Execution = "OutputLimit"
	case stopped != "":
		result.Execution = stopped
	case exit == 132 || exit == 133 || exit == 134 || exit == 139:
		result.Execution = "CandidateCrash"
	case exit == 159:
		result.Execution = "SandboxDenied"
	case exit == 1:
		result.Execution = "GuestRejected"
	case waitErr == nil && exit == 0 && result.FirstError == nil && reflect.DeepEqual(result.Trace, expected) && len(result.Choices) == len(replies):
		result.Execution = model.Execution
	default:
		result.Execution = "HarnessError"
	}
	if result.FirstError != nil && result.FirstError["kind"] == "RecordMismatch" {
		result.Conformance = "Diverged"
	} else if result.Execution == "Completed" || result.Execution == "BudgetExhausted" {
		result.Conformance = "Admitted"
	}
	return result, nil
}

type nativeAdmission struct {
	Data   map[string]any `json:"data"`
	Header string         `json:"header"`
}

func decodeNativeAdmission(b []byte) (nativeAdmission, error) {
	var admitted nativeAdmission
	if e := checkLoweringEnvelope(b); e != nil {
		return admitted, e
	}
	e := decodeHostJSON(b, &admitted)
	if e == nil && admitted.Data == nil {
		e = fmt.Errorf("NativeAdmissionDataRequired")
	}
	return admitted, e
}

func admitNative(root, path, artifact, input string) (report buildReport, data map[string]any, err error) {
	if e := loadJSON(path, &report); e != nil {
		return report, nil, e
	}
	if report.Schema != nativeBuildSchema || report.Profile != profile || report.Qualification != "UNKNOWN" || report.Cleanup != "confirmed" || !report.Equal || !reflect.DeepEqual(report.Before, report.After) {
		return report, nil, fmt.Errorf("NativeBuildReceipt")
	}
	if e := verifyBuildSources(root, report); e != nil {
		return report, nil, e
	}
	// Resource/ambiguity preflight only. Node remains semantic authority.
	for _, p := range []string{artifact, input} {
		var raw any
		if e := loadJSON(p, &raw); e != nil {
			return report, nil, e
		}
	}
	if e := validateBuildCompileCommand(report); e != nil {
		return report, nil, e
	}
	dep, e := admitDependency(root, filepath.Join(root, report.DependencyPath))
	if e != nil {
		return report, nil, e
	}
	if dep.Image != report.Image || dep.Tender != report.Tender {
		return report, nil, fmt.Errorf("TransportDependencyIdentity")
	}
	h, e := digest(filepath.Join(filepath.Dir(path), "guest.spt"))
	if e != nil || h != report.Guest {
		return report, nil, fmt.Errorf("GuestBinaryDrift")
	}
	out, e := synchronous(root, []string{"node", filepath.Join(root, "tools/solo5/native-arithmetic/admit.mjs"), artifact, input}, 30*time.Second)
	if e != nil || len(out.Stdout) > maxNativeAdmissionBytes {
		return report, nil, fmt.Errorf("ClosedArtifactAdmission: %v", e)
	}
	admitted, e := decodeNativeAdmission([]byte(out.Stdout))
	if e != nil {
		return report, nil, e
	}
	if hashBytes([]byte(admitted.Header)) != report.Data {
		return report, nil, fmt.Errorf("LoweredDataDrift")
	}
	image, e := inspect(root, "image", "inspect", report.Image)
	if e != nil || image.ID != report.Image {
		return report, nil, fmt.Errorf("ImageIdentity")
	}
	return report, admitted.Data, nil
}
