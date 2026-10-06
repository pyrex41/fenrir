package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os/exec"
	"reflect"
	"strings"
	"time"
)

type mount struct {
	Source      string `json:"source"`
	Destination string `json:"destination"`
}
type dockerInfo struct {
	ID     string `json:"Id"`
	Path   string
	Args   []string
	Image  string
	RootFS struct{ Layers []string }
	Config struct {
		User       string
		Cmd        []string
		Entrypoint []string
		OpenStdin  bool
		Tty        bool
		Labels     map[string]string
	}
	HostConfig struct {
		NetworkMode    string
		Privileged     bool
		ReadonlyRootfs bool
		CapDrop        []string
		SecurityOpt    []string
		Devices        []any
		Memory         int64
		PidsLimit      int
		Tmpfs          map[string]string
	}
	Mounts []struct {
		Type        string
		Source      string
		Destination string
		RW          bool
	}
}

func inspect(root string, args ...string) (dockerInfo, error) {
	var info dockerInfo
	r, e := synchronous(root, append([]string{"docker"}, args...), 15*time.Second)
	if e != nil {
		return info, fmt.Errorf("DockerInspect: %w: %s", e, r.Stderr)
	}
	return decodeDockerInspect([]byte(r.Stdout))
}

// Docker metadata is an open daemon envelope, not a closed host report.
func decodeDockerInspect(b []byte) (dockerInfo, error) {
	var info dockerInfo
	if _, e := hostJSONValue(b); e != nil {
		return info, fmt.Errorf("DockerInspectJSON: %w", e)
	}
	var rows []dockerInfo
	if e := json.Unmarshal(b, &rows); e != nil || len(rows) != 1 {
		return info, fmt.Errorf("DockerInspectShape")
	}
	return rows[0], nil
}
func token() (string, error) {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return hex.EncodeToString(b), nil
}
func checkPolicy(info dockerInfo, mounts []mount, writable, stdin bool, launch ...[]string) error {
	h, c := info.HostConfig, info.Config
	if len(launch) > 1 {
		return fmt.Errorf("ContainerLaunchIdentity")
	}
	if len(launch) == 1 {
		command := launch[0]
		if len(command) == 0 || len(c.Entrypoint) != 0 || !reflect.DeepEqual(c.Cmd, command) || info.Path != command[0] || !reflect.DeepEqual(info.Args, command[1:]) {
			return fmt.Errorf("ContainerLaunchIdentity")
		}
	}
	if h.NetworkMode != "none" || h.Privileged || !h.ReadonlyRootfs || !reflect.DeepEqual(h.CapDrop, []string{"ALL"}) || c.User != "65534:65534" || !contains(h.SecurityOpt, "no-new-privileges") || len(h.Devices) != 0 || h.Memory != 134217728 || h.PidsLimit != 32 || c.OpenStdin != stdin || c.Tty {
		return fmt.Errorf("ContainerPolicy")
	}
	want := map[mount]bool{}
	for _, m := range mounts {
		want[m] = false
	}
	got := map[mount]bool{}
	for _, m := range info.Mounts {
		if m.Type == "bind" {
			key := mount{m.Source, m.Destination}
			if _, ok := got[key]; ok {
				return fmt.Errorf("DuplicateMount")
			}
			got[key] = m.RW
		} else if m.Type != "tmpfs" {
			return fmt.Errorf("UnexpectedMountType")
		}
	}
	if !reflect.DeepEqual(got, want) {
		return fmt.Errorf("BindMountPolicy")
	}
	if writable {
		if len(h.Tmpfs) != 1 || h.Tmpfs["/work"] != "rw,nosuid,size=32m,mode=1777" {
			return fmt.Errorf("BuildTmpfsPolicy")
		}
	} else if len(h.Tmpfs) != 0 {
		return fmt.Errorf("UnexpectedTmpfs")
	}
	return nil
}
func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}
func dockerArgs(name, owner, image string, mounts []mount, writable, stdin bool) []string {
	a := []string{"docker", "run", "--name", name, "--label", "org.fenrir.probe.owner=" + owner, "--read-only", "--network", "none", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--user", "65534:65534", "--memory", "128m", "--pids-limit", "32"}
	if writable {
		a = append(a, "--tmpfs", "/work:rw,nosuid,size=32m,mode=1777")
	}
	if stdin {
		a = append(a, "-i")
	}
	for _, m := range mounts {
		a = append(a, "--mount", "type=bind,src="+m.Source+",dst="+m.Destination+",readonly")
	}
	return append(a, image)
}
func removeContainer(root, name string) error {
	r, e := synchronous(root, []string{"docker", "rm", "-f", name}, 15*time.Second)
	if e != nil {
		return fmt.Errorf("ContainerRemovalUnresolved: %w: %s", e, r.Stderr)
	}
	if r.Exit != 0 {
		return fmt.Errorf("ContainerRemovalUnresolved: %s", r.Stderr)
	}
	r, e = synchronous(root, []string{"docker", "inspect", name}, 15*time.Second)
	return validateContainerAbsence(name, r, e)
}

// Shared by removal and explicitly authorized read-only ownership review.
// The subprocess error must retain its exact class; text alone proves nothing.
func validateContainerAbsence(name string, r commandResult, e error) error {
	expected := "no such object: " + name
	s := strings.ToLower(strings.TrimSpace(r.Stderr))
	s = strings.TrimPrefix(s, "error: ")
	// Only Wait's direct exit-status error is expected here. An inspection,
	// watchdog, output-cap or ownership error cannot prove container absence,
	// even when the Docker process happened to emit the expected text.
	exitError, expectedExit := e.(*exec.ExitError)
	if !expectedExit || exitError.ExitCode() != 1 || r.Exit != 1 || strings.TrimSpace(r.Stdout) != "[]" || s != expected {
		if e != nil {
			return fmt.Errorf("ContainerAbsenceUnresolved: %w: %s", e, r.Stderr)
		}
		return fmt.Errorf("ContainerAbsenceUnresolved: %s", r.Stderr)
	}
	return nil
}
func isolatedBuild(root, image string, mounts []mount, command, diagnosticsDir string) (result commandResult, err error) {
	id, e := token()
	if e != nil {
		return result, e
	}
	owner, e := token()
	if e != nil {
		return result, e
	}
	name := "fenrir-solo5-native-build-" + id[:16]
	pgid := 0
	launch := []string{"sh", "-c", command}
	argv := append(dockerArgs(name, owner, image, mounts, true, false), launch...)
	defer func() {
		primary := err
		cleanup := removeContainer(root, name)
		if cleanup != nil {
			err = cleanup
		}
		if e := persistOwnedFailure(diagnosticsDir, id, "isolated-build", name, owner, argv, pgid, primary, cleanup); e != nil {
			err = fmt.Errorf("%v; %w", err, e)
		}
	}()
	result, err = runOwnedCommandCapture(root, argv, 60*time.Second, true, &pgid)
	info, e := inspect(root, "inspect", name)
	if e != nil {
		return result, e
	}
	if info.Image != image || info.Config.Labels["org.fenrir.probe.owner"] != owner {
		return result, fmt.Errorf("ContainerIdentity")
	}
	if e = checkPolicy(info, mounts, true, false, launch); e != nil {
		return result, e
	}
	return result, err
}
