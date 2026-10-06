package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func bridgeFixture(t *testing.T, change func(map[string]any)) []byte {
	t.Helper()
	data := map[string]any{
		"schema":          "fenrir.solo5.native-arithmetic-lowering/1",
		"artifact_sha256": "artifact", "input_sha256": "input",
		"parameter": "1", "input": []any{"unit"}, "root": 0,
		"rows": []any{map[string]any{"tag": "unit", "id": "2", "binding": "0", "op": "none", "literal": []any{"unit"}, "label": "", "children": []any{}}},
	}
	if change != nil {
		change(data)
	}
	b, e := json.Marshal(map[string]any{"data": data, "header": "h"})
	if e != nil {
		t.Fatal(e)
	}
	return b
}

// Optional integration vectors are real Node lowerings, not guest execution.
func TestNativeBridgeRealNodeLowering(t *testing.T) {
	dir := os.Getenv("FENRIR_BRIDGE_FIXTURES")
	if dir == "" {
		t.Skip("explicit Node-generated bridge fixture directory required")
	}
	paths, e := filepath.Glob(filepath.Join(dir, "*.bridge.json"))
	if e != nil || len(paths) != 13 {
		t.Fatalf("expected all 13 hand lowerings, got %d: %v", len(paths), e)
	}
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			b, e := readHostJSON(path)
			if e != nil {
				t.Fatal(e)
			}
			got, e := decodeNativeAdmission(b)
			if e != nil {
				t.Fatal(e)
			}
			var prior nativeAdmission
			if e := decodeHostJSON(b, &prior); e != nil {
				t.Fatal(e)
			}
			if !reflect.DeepEqual(got, prior) {
				t.Fatal("nested validation changed retained data/header")
			}
		})
	}
}

func TestNativeBridgeSharedByteLimit(t *testing.T) {
	b := bridgeFixture(t, nil)
	b = append(b, bytes.Repeat([]byte(" "), 131072-len(b))...)
	if _, e := decodeNativeAdmission(b); e != nil {
		t.Fatalf("bridge byte boundary rejected: %v", e)
	}
	if _, e := decodeNativeAdmission(append(b, ' ')); e == nil || e.Error() != "NativeAdmissionByteLimit" {
		t.Fatalf("expected shared bridge overflow rejection: %v", e)
	}
}

func TestNativeBridgeNestedClosedShape(t *testing.T) {
	cases := map[string]func(map[string]any){
		"missing":          func(d map[string]any) { delete(d, "parameter") },
		"unknown":          func(d map[string]any) { d["extra"] = true },
		"wrong schema":     func(d map[string]any) { d["schema"] = "wrong" },
		"null input":       func(d map[string]any) { d["input"] = nil },
		"wrong input type": func(d map[string]any) { d["input"] = "unit" },
		"null rows":        func(d map[string]any) { d["rows"] = nil },
		"empty rows":       func(d map[string]any) { d["rows"] = []any{} },
		"too many rows": func(d map[string]any) {
			row := d["rows"].([]any)[0]
			rows := make([]any, 101)
			for i := range rows {
				rows[i] = row
			}
			d["rows"] = rows
		},
		"fractional root":   func(d map[string]any) { d["root"] = 0.5 },
		"negative root":     func(d map[string]any) { d["root"] = -1 },
		"outside root":      func(d map[string]any) { d["root"] = 1 },
		"row unknown":       func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["extra"] = 1 },
		"row missing":       func(d map[string]any) { delete(d["rows"].([]any)[0].(map[string]any), "tag") },
		"row null":          func(d map[string]any) { d["rows"] = []any{nil} },
		"wrong ID type":     func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["id"] = 2 },
		"null literal":      func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["literal"] = nil },
		"null children":     func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["children"] = nil },
		"too many children": func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["children"] = []any{0, 0, 0, 0} },
		"negative child":    func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["children"] = []any{-1} },
		"outside child":     func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["children"] = []any{1} },
		"fractional child":  func(d map[string]any) { d["rows"].([]any)[0].(map[string]any)["children"] = []any{0.5} },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			if _, e := decodeNativeAdmission(bridgeFixture(t, change)); e == nil {
				t.Fatal("invalid nested bridge data admitted")
			}
		})
	}
	if _, e := decodeNativeAdmission(bridgeFixture(t, nil)); e != nil {
		t.Fatal(e)
	}
}
