package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Distinguishes preflight rejection from a later source/oracle/guest failure.
// Missing inputs and an empty PATH make any external launch unavailable.
func TestModeRejectedBeforeInputAdmission(t *testing.T) {
	for _, mode := range []string{"", "NORMAL", "wrong", "0"} {
		for _, command := range []string{"session", "replay"} {
			t.Run(command+"-"+mode, func(t *testing.T) {
				root := t.TempDir()
				output := filepath.Join(root, "never-output.json")
				t.Setenv("PATH", t.TempDir())
				args := []string{"--root", root, "--build-report", filepath.Join(root, "missing-build"), "--artifact", filepath.Join(root, "missing-artifact"), "--input", filepath.Join(root, "missing-input"), "--shen-executable", filepath.Join(root, "missing-shen"), "--output", output, "--mode", mode}
				if command == "replay" {
					args = append(args, "--original", filepath.Join(root, "missing-original"))
				}
				var e error
				if command == "session" {
					e = sessionCLI(args)
				} else {
					e = replayCLI(args)
				}
				if e == nil || e.Error() != "CandidateMode" {
					t.Fatalf("expected mode rejection before input/oracle/guest: %v", e)
				}
				if _, e := os.Lstat(output); !os.IsNotExist(e) {
					t.Fatal("preflight rejection created output")
				}
			})
		}
	}
}

func TestSupportedModesReachInputAdmission(t *testing.T) {
	for _, mode := range []string{"normal", "mutant"} {
		root := t.TempDir()
		args := []string{"--root", root, "--build-report", "missing-build", "--artifact", "missing-artifact", "--input", "missing-input", "--shen-executable", "missing-shen", "--output", filepath.Join(root, "never-output.json"), "--mode", mode}
		if e := sessionCLI(args); e == nil || e.Error() == "CandidateMode" {
			t.Fatalf("supported mode did not reach admission: %v", e)
		}
	}
}
