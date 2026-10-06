package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeBridgeClosedEnvelope(t *testing.T) {
	for name, body := range map[string]string{
		"duplicate":   `{"data":{},"header":"first","header":"second"}`,
		"unknown":     `{"data":{},"header":"h","extra":1}`,
		"missing":     `{"data":{}}`,
		"null data":   `{"data":null,"header":"h"}`,
		"null header": `{"data":{},"header":null}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, e := decodeNativeAdmission([]byte(body)); e == nil {
				t.Fatal("unsafe bridge envelope admitted")
			}
		})
	}
	if _, e := decodeNativeAdmission([]byte(`{"data":{"root":0},"header":"h"}`)); e != nil {
		t.Fatal(e)
	}
}

func TestNativeInputPreflightBeforeDependency(t *testing.T) {
	for _, target := range []string{"artifact", "input"} {
		t.Run(target, func(t *testing.T) {
			root := t.TempDir()
			artifact, input := filepath.Join(root, "artifact.json"), filepath.Join(root, "input.json")
			for _, p := range []string{artifact, input} {
				if e := os.WriteFile(p, []byte(`{}`), 0600); e != nil {
					t.Fatal(e)
				}
			}
			huge := artifact
			if target == "input" {
				huge = input
			}
			if e := os.WriteFile(huge, []byte(strings.Repeat(" ", maxHostJSONBytes+1)), 0600); e != nil {
				t.Fatal(e)
			}
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
			r := buildReport{Schema: "fenrir.solo5.native-arithmetic-build/1", Profile: profile, Qualification: "UNKNOWN", Cleanup: "confirmed", Equal: true, Before: hashes, After: hashes, DataPath: "data.h", DependencyPath: "dependency.json", Data: hashes["data.h"], Dependency: hashes["dependency.json"]}
			build := filepath.Join(root, "build.json")
			if e := writeJSONFresh(build, r); e != nil {
				t.Fatal(e)
			}
			_, _, e = admitNative(root, build, artifact, input)
			if e == nil || !strings.Contains(e.Error(), "HostJSONByteLimit") {
				t.Fatalf("expected preflight before dependency/build/guest: %v", e)
			}
		})
	}
}
