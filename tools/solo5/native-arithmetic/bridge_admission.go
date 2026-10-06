package main

import (
	"fmt"
)

const maxNativeAdmissionBytes = 131072

// Adapter envelope shape only: Node remains artifact/semantic authority. These
// types close the nested bridge keys and bound indices consumed by the host.
// They do not validate AST transitions. Header comparison checks the data-only
// representation, not artifact semantics or the correctness of claimed hashes.
type loweringRow struct {
	Tag      string `json:"tag"`
	ID       string `json:"id"`
	Binding  string `json:"binding"`
	Op       string `json:"op"`
	Literal  []any  `json:"literal"`
	Label    string `json:"label"`
	Children []int  `json:"children"`
}

type loweringData struct {
	Schema    string        `json:"schema"`
	Artifact  string        `json:"artifact_sha256"`
	InputHash string        `json:"input_sha256"`
	Parameter string        `json:"parameter"`
	Input     []any         `json:"input"`
	Root      int           `json:"root"`
	Rows      []loweringRow `json:"rows"`
}

type loweringEnvelope struct {
	Data   loweringData `json:"data"`
	Header string       `json:"header"`
}

func checkLoweringEnvelope(b []byte) error {
	if len(b) > maxNativeAdmissionBytes {
		return fmt.Errorf("NativeAdmissionByteLimit")
	}
	var envelope loweringEnvelope
	if e := decodeHostJSON(b, &envelope); e != nil {
		return e
	}
	d := envelope.Data
	if d.Schema != "fenrir.solo5.native-arithmetic-lowering/1" {
		return fmt.Errorf("NativeAdmissionSchema")
	}
	if d.Input == nil || len(d.Rows) < 1 || len(d.Rows) > 100 || d.Root < 0 || d.Root >= len(d.Rows) {
		return fmt.Errorf("NativeAdmissionDataBounds")
	}
	for _, row := range d.Rows {
		if row.Literal == nil || row.Children == nil || len(row.Children) > 3 {
			return fmt.Errorf("NativeAdmissionRowBounds")
		}
		for _, child := range row.Children {
			if child < 0 || child >= len(d.Rows) {
				return fmt.Errorf("NativeAdmissionChildBounds")
			}
		}
	}
	header, e := loweringDataHeader(d)
	if e != nil {
		return e
	}
	if envelope.Header != header {
		return fmt.Errorf("NativeAdmissionHeaderMismatch")
	}
	return nil
}
