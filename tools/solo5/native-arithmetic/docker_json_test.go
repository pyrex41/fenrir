package main

import (
	"strings"
	"testing"
)

func TestDockerInspectOpenButBounded(t *testing.T) {
	for name, body := range map[string]string{
		"duplicate":        `[{"Id":"first","Id":"second"}]`,
		"nested duplicate": `[{"Metadata":{"x":1,"x":2}}]`,
		"deep":             `[{"Metadata":` + strings.Repeat("[", 130) + `0` + strings.Repeat("]", 130) + `}]`,
		"bytes":            `[{"Metadata":"` + strings.Repeat("x", maxHostJSONBytes) + `"}]`,
		"values":           `[{"Metadata":[` + strings.Repeat("0,", maxHostJSONValues) + `0]}]`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, e := decodeDockerInspect([]byte(body)); e == nil {
				t.Fatal("unbounded or ambiguous daemon metadata admitted")
			}
		})
	}
	// Ignore extra daemon fields deliberately; closing a partial struct would
	// reject ordinary Docker versions and is not the intended policy.
	d, e := decodeDockerInspect([]byte(`[{"Id":"sha256:test","DaemonExtra":{"Version":1}}]`))
	if e != nil || d.ID != "sha256:test" {
		t.Fatalf("open metadata compatibility: %+v %v", d, e)
	}
}
