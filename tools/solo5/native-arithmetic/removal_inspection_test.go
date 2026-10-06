package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// Preflight fault injection only. Both executables are local shell fixtures;
// no real Docker removal, guest build, guest execution, or daemon fault occurs.
func TestRemovalRejectsInspectionFailureDespiteNoSuchObject(t *testing.T) {
	dir := t.TempDir()
	counter := filepath.Join(dir, "ps-count")
	ps := "#!/bin/sh\nif [ ! -f '" + counter + "' ]; then\n printf x > '" + counter + "'\n printf '123 456 S\\n'\nelse\n printf 'malformed inspection row\\n'\nfi\n"
	docker := "#!/bin/sh\ncase \"$1\" in\n rm) printf 'exact-owned-name\\n'; exit 0;;\n inspect) printf '[]\\n'; printf 'Error: No such object: exact-owned-name\\n' >&2; exit 1;;\n *) exit 99;;\nesac\n"
	for name, script := range map[string]string{"ps": ps, "docker": docker} {
		if e := os.WriteFile(filepath.Join(dir, name), []byte(script), 0700); e != nil {
			t.Fatal(e)
		}
	}
	t.Setenv("PATH", dir)
	e := removeContainer(dir, "exact-owned-name")
	if e == nil {
		t.Fatal("cleanup inspection failure was silently accepted as confirmed container absence")
	}
	var detail *cleanupInspectionError
	if !errors.As(e, &detail) || detail.TargetPGID <= 0 || detail.OffendingRow != "malformed inspection row" {
		t.Fatalf("cleanup diagnostic was lost: %v", e)
	}
}

func TestRemovalAcceptsOnlyExactExpectedAbsence(t *testing.T) {
	for _, tc := range []struct {
		name, inspect string
		accept        bool
	}{
		{"expected", "printf '[]\\n'; printf 'Error: No such object: exact-owned-name\\n' >&2; exit 1", true},
		{"wrong exit", "printf '[]\\n'; printf 'Error: No such object: exact-owned-name\\n' >&2; exit 2", false},
		{"successful inspect", "printf '[]\\n'; printf 'Error: No such object: exact-owned-name\\n' >&2; exit 0", false},
		{"wrong name", "printf '[]\\n'; printf 'Error: No such object: unrelated\\n' >&2; exit 1", false},
		{"daemon error", "printf '[]\\n'; printf 'Cannot connect to Docker daemon\\n' >&2; exit 1", false},
		{"extra output", "printf '[] extra\\n'; printf 'Error: No such object: exact-owned-name\\n' >&2; exit 1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			fixtures := map[string]string{
				"ps":     "#!/bin/sh\nprintf '123 456 S\\n'\n",
				"docker": "#!/bin/sh\ncase \"$1\" in\nrm) exit 0;;\ninspect) " + tc.inspect + ";;\n*) exit 99;;\nesac\n",
			}
			for name, script := range fixtures {
				if e := os.WriteFile(filepath.Join(dir, name), []byte(script), 0700); e != nil {
					t.Fatal(e)
				}
			}
			t.Setenv("PATH", dir)
			e := removeContainer(dir, "exact-owned-name")
			if (e == nil) != tc.accept {
				t.Fatalf("accept=%v, got %v", tc.accept, e)
			}
		})
	}
}
