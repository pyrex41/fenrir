package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Data-only fake inventory: source identities are internally consistent, but
// the transport receipt is deliberately invalid. No Node/Docker is available.
func TestNativeFuelRejectedBeforeDependencyTooling(t *testing.T) {
	for _, fuel := range []string{"04", "+4", "-0", "201"} {
		t.Run(fuel, func(t *testing.T) {
			root := t.TempDir()
			files := []string{}
			for _, name := range []string{
				"tools/solo5/native-arithmetic/main.go", "tools/solo5/native-arithmetic/go.mod",
				"backends/solo5/native-arithmetic/machine.h", "backends/solo5/native-arithmetic/machine.c",
				"backends/solo5/native-arithmetic/format.h", "backends/solo5/native-arithmetic/format.c",
				"backends/solo5/native-arithmetic/guest.c", "backends/solo5/protocol.h", "backends/solo5/protocol.c",
				"tools/solo5/native-arithmetic/lower.mjs", "tools/solo5/native-arithmetic/admit.mjs",
				"tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs", "data.h", "dependency.json",
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
			r := buildReport{Schema: "fenrir.solo5.native-arithmetic-build/1", Qualification: "UNKNOWN", Profile: profile, Cleanup: "confirmed", Equal: true, Before: hashes, After: hashes, DataPath: "data.h", DependencyPath: "dependency.json", Data: hashes["data.h"], Dependency: hashes["dependency.json"], Fuel: fuel}
			build := filepath.Join(root, "build.json")
			if e = writeJSONFresh(build, r); e != nil {
				t.Fatal(e)
			}
			artifact, input := filepath.Join(root, "artifact.json"), filepath.Join(root, "input.json")
			for _, p := range []string{artifact, input} {
				if e = os.WriteFile(p, []byte(`{}`), 0600); e != nil {
					t.Fatal(e)
				}
			}
			t.Setenv("PATH", t.TempDir())
			if _, _, e := admitNative(root, build, artifact, input); e == nil || e.Error() != "BuildFuelBounds" {
				t.Fatalf("fuel was not rejected before transport/Node tooling: %v", e)
			}
		})
	}
}
