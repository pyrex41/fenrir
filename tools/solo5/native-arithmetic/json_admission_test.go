package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHostJSONDistinguishingNegatives(t *testing.T) {
	type envelope struct {
		Name  string `json:"name"`
		Count int    `json:"count"`
	}
	cases := map[string]string{
		"duplicate":          `{"name":"a","name":"b","count":1}`,
		"unknown":            `{"name":"a","count":1,"extra":true}`,
		"missing":            `{"name":"a"}`,
		"null scalar":        `{"name":null,"count":1}`,
		"wrong type":         `{"name":"a","count":"1"}`,
		"fractional integer": `{"name":"a","count":1.5}`,
		"trailing":           `{"name":"a","count":1} {}`,
		"deep":               `{"name":"a","count":1,"extra":` + strings.Repeat("[", 130) + `0` + strings.Repeat("]", 130) + `}`,
		"byte cap":           `{"name":"` + strings.Repeat("a", 4*1024*1024) + `","count":1}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "report.json")
			if e := os.WriteFile(p, []byte(body), 0600); e != nil {
				t.Fatal(e)
			}
			var v envelope
			if e := loadJSON(p, &v); e == nil {
				t.Fatal("unsafe envelope admitted")
			}
		})
	}
}

// Explicit opt-in: absence of local historical evidence is not compatibility PASS.
func TestRetainedHostJSONCompatibility(t *testing.T) {
	root := os.Getenv("FENRIR_ADMISSION_BASELINE_ROOT")
	if root == "" {
		t.Skip("explicit baseline root required")
	}
	var dep dependencyReport
	if e := loadJSON(filepath.Join(root, "build/solo5/control-build-5b98ecf8/build.json"), &dep); e != nil {
		t.Fatal(e)
	}
	var build buildReport
	if e := loadJSON(filepath.Join(root, "build/solo5/native-arithmetic-2032a056/generated-1/case_00-build/build.json"), &build); e != nil {
		t.Fatal(e)
	}
	var bundle sessionBundle
	if e := loadJSON(filepath.Join(root, "build/solo5/native-arithmetic-2032a056/generated-1/case_00-mutant.json"), &bundle); e != nil {
		t.Fatal(e)
	}
	if dep.Schema != "fenrir.solo5.control-build/1" || build.Profile != profile || bundle.Result.Conformance != "Diverged" {
		t.Fatal("retained envelope meaning changed")
	}
}

func TestHostJSONAllowsDiagnosticNumbers(t *testing.T) {
	type envelope struct {
		Name  string `json:"name"`
		Count int    `json:"count"`
	}
	p := filepath.Join(t.TempDir(), "report.json")
	if e := os.WriteFile(p, []byte(`{"name":"a","count":1}`), 0600); e != nil {
		t.Fatal(e)
	}
	var v envelope
	if e := loadJSON(p, &v); e != nil || v.Count != 1 {
		t.Fatalf("diagnostic integer rejected: %+v %v", v, e)
	}
}
