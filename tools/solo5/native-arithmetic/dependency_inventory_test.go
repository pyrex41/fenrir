package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These literals deliberately do not come from the implementation inventory.
func dependencyFixture(t *testing.T) (string, map[string]string) {
	t.Helper()
	root := t.TempDir()
	files := []string{}
	for _, name := range []string{
		"tools/solo5/build-control-stdin.py", "tools/solo5/baseline.py", "tools/solo5/transport-feasibility.py",
		"backends/solo5/overlays/control-stdin/overlay.py", "build/vendor/solo5/tenders/spt/spt_core.c", "backends/solo5/Dockerfile",
	} {
		p := filepath.Join(root, name)
		if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(p, []byte(name), 0600); e != nil {
			t.Fatal(e)
		}
		files = append(files, p)
	}
	hashes, e := sourceHashes(root, files)
	if e != nil {
		t.Fatal(e)
	}
	return root, hashes
}

func TestDependencyInventoryExactSet(t *testing.T) {
	root, hashes := dependencyFixture(t)
	if e := verifyDependencyInventory(root, hashes); e != nil {
		t.Fatal(e)
	}
	for omitted := range hashes {
		t.Run(omitted, func(t *testing.T) {
			partial := map[string]string{}
			for p, h := range hashes {
				if p != omitted {
					partial[p] = h
				}
			}
			if e := verifyDependencyInventory(root, partial); e == nil {
				t.Fatal("omitted dependency admitted")
			}
		})
	}
	// Disk drift must also fail even when both receipt maps agree.
	if e := os.WriteFile(filepath.Join(root, "backends/solo5/Dockerfile"), []byte("drift"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := verifyDependencyInventory(root, hashes); e == nil {
		t.Fatal("disk drift admitted")
	}
}

func TestDependencyInventoryRejectsBeforeDocker(t *testing.T) {
	for _, mutation := range []string{"omit", "extra", "swap"} {
		t.Run(mutation, func(t *testing.T) {
			root, hashes := dependencyFixture(t)
			switch mutation {
			case "omit":
				delete(hashes, "tools/solo5/baseline.py")
			case "extra":
				p := filepath.Join(root, "extra")
				if e := os.WriteFile(p, []byte("extra"), 0600); e != nil {
					t.Fatal(e)
				}
				hashes["extra"] = hashBytes([]byte("extra"))
			case "swap":
				hashes["tools/solo5/baseline.py"] = hashBytes([]byte("wrong"))
			}
			receipt := filepath.Join(root, "receipt.json")
			r := dependencyReport{Schema: "fenrir.solo5.control-build/1", Qualification: "UNKNOWN", Cleanup: "confirmed", Equal: true, Before: hashes, After: hashes}
			if e := writeJSONFresh(receipt, r); e != nil {
				t.Fatal(e)
			}
			// No Docker executable is visible. Admission must reject at the source
			// inventory boundary, before inspecting even an image.
			t.Setenv("PATH", t.TempDir())
			_, e := admitDependency(root, receipt)
			if e == nil || !strings.Contains(e.Error(), "DependencyRequiredSourceSetOrIdentity") {
				t.Fatalf("wanted independent inventory rejection before Docker, got %v", e)
			}
		})
	}
}
