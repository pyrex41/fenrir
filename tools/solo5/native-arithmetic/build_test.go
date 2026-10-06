package main

import (
	"os"
	"path/filepath"
	"testing"
)

func policyFixture() dockerInfo {
	var d dockerInfo
	d.Image = "sha256:test"
	d.Config.User = "65534:65534"
	d.HostConfig.NetworkMode = "none"
	d.HostConfig.ReadonlyRootfs = true
	d.HostConfig.CapDrop = []string{"ALL"}
	d.HostConfig.SecurityOpt = []string{"no-new-privileges"}
	d.HostConfig.Memory = 134217728
	d.HostConfig.PidsLimit = 32
	return d
}
func TestContainerPolicy(t *testing.T) {
	d := policyFixture()
	if e := checkPolicy(d, []mount{}, false, false); e != nil {
		t.Fatal(e)
	}
	for name, mutate := range map[string]func(*dockerInfo){"network": func(d *dockerInfo) { d.HostConfig.NetworkMode = "host" }, "privileged": func(d *dockerInfo) { d.HostConfig.Privileged = true }, "root": func(d *dockerInfo) { d.HostConfig.ReadonlyRootfs = false }, "caps": func(d *dockerInfo) { d.HostConfig.CapDrop = nil }, "security": func(d *dockerInfo) { d.HostConfig.SecurityOpt = nil }, "user": func(d *dockerInfo) { d.Config.User = "0" }, "memory": func(d *dockerInfo) { d.HostConfig.Memory = 0 }, "pids": func(d *dockerInfo) { d.HostConfig.PidsLimit = 0 }, "stdin": func(d *dockerInfo) { d.Config.OpenStdin = true }, "tty": func(d *dockerInfo) { d.Config.Tty = true }, "tmpfs": func(d *dockerInfo) { d.HostConfig.Tmpfs = map[string]string{"/escape": "rw"} }} {
		t.Run(name, func(t *testing.T) {
			d := policyFixture()
			mutate(&d)
			if checkPolicy(d, []mount{}, false, false) == nil {
				t.Fatal("admitted policy mutation")
			}
		})
	}
	d = policyFixture()
	d.HostConfig.Tmpfs = map[string]string{"/work": "rw,nosuid,size=32m,mode=1777"}
	if e := checkPolicy(d, []mount{}, true, false); e != nil {
		t.Fatal(e)
	}
	d.HostConfig.Tmpfs["/work"] = "rw,exec"
	if checkPolicy(d, []mount{}, true, false) == nil {
		t.Fatal("admitted weaker tmpfs")
	}
}
func TestSourceSeal(t *testing.T) {
	root := t.TempDir()
	p := filepath.Join(root, "input")
	if e := os.WriteFile(p, []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	m, e := sourceHashes(root, []string{p})
	if e != nil {
		t.Fatal(e)
	}
	if e = verifyHashes(root, m); e != nil {
		t.Fatal(e)
	}
	os.WriteFile(p, []byte("changed"), 0600)
	if verifyHashes(root, m) == nil {
		t.Fatal("drift admitted")
	}
	if verifyHashes(root, map[string]string{}) == nil {
		t.Fatal("empty identity admitted")
	}
	if verifyHashes(root, map[string]string{"../escape": "bad"}) == nil {
		t.Fatal("escape admitted")
	}
	outside := filepath.Join(t.TempDir(), "outside")
	os.WriteFile(outside, []byte("outside"), 0600)
	link := filepath.Join(root, "link")
	if e = os.Symlink(outside, link); e != nil {
		t.Fatal(e)
	}
	if _, e = sealedPath(root, link); e == nil {
		t.Fatal("symlink escape admitted")
	}
}
func TestFreshOutput(t *testing.T) {
	root := t.TempDir()
	base := filepath.Join(root, "build/solo5")
	if e := os.MkdirAll(base, 0755); e != nil {
		t.Fatal(e)
	}
	dest := filepath.Join(base, "fresh")
	if e := freshDirectory(root, dest); e != nil {
		t.Fatal(e)
	}
	if freshDirectory(root, dest) == nil {
		t.Fatal("reused output")
	}
	if freshDirectory(root, filepath.Join(root, "escape")) == nil {
		t.Fatal("outside output")
	}
}
