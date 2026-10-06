package main

import (
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestV1BuildReceiptNotReinterpreted(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	root := t.TempDir()
	path := filepath.Join(root, "historical-build.json")
	r := buildReport{Schema: "fenrir.solo5.native-arithmetic-build/1", Profile: profile, Qualification: "UNKNOWN", Cleanup: "confirmed", Equal: true, Command: []string{"host", "build"}, Fuel: "4"}
	if e := writeJSONFresh(path, r); e != nil {
		t.Fatal(e)
	}
	if _, _, e := admitNative(root, path, "unused", "unused"); e == nil || e.Error() != "NativeBuildReceipt" {
		t.Fatalf("v1 advisory receipt reinterpreted: %v", e)
	}
}

func TestBuildCompileCommandContradictions(t *testing.T) {
	valid := []string{"sh", "-c", nativeCompileScript(4)}
	for name, command := range map[string][]string{
		"missing":       nil,
		"advisory argv": {"host", "build", "--fuel", "4"},
		"executable":    {"bash", "-c", valid[2]},
		"flag":          {"sh", "-x", valid[2]},
		"fuel":          {"sh", "-c", nativeCompileScript(3)},
		"extra":         {"sh", "-c", valid[2], "extra"},
		"recipe":        {"sh", "-c", strings.Replace(valid[2], "-Werror", "", 1)},
	} {
		t.Run(name, func(t *testing.T) {
			if e := validateBuildCompileCommand(buildReport{Fuel: "4", CompileCommand: command}); e == nil {
				t.Fatal("contradictory compile command admitted")
			}
		})
	}
	for _, fuel := range []int{0, 4, 200} {
		if e := validateBuildCompileCommand(buildReport{Fuel: strconv.Itoa(fuel), CompileCommand: []string{"sh", "-c", nativeCompileScript(fuel)}}); e != nil {
			t.Fatal(e)
		}
	}
}
