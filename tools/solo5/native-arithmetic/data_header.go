package main

import (
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var loweringLabel = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)

// Representation-only mirror of lower.mjs:dataHeader. No AST validation,
// transition computation, input hashing or compiler/binary attestation lives here.
// Reject unsafe/unrepresentable tokens rather than parsing arbitrary C. Equality
// is byte-exact: this adapter does not admit alternate C spellings or appended code.
func loweringDataHeader(d loweringData) (string, error) {
	bad := func() (string, error) { return "", fmt.Errorf("NativeAdmissionHeaderData") }
	for _, hash := range []string{d.Artifact, d.InputHash} {
		b, e := hex.DecodeString(hash)
		if e != nil || len(b) != 32 || hash != strings.ToLower(hash) {
			return bad()
		}
	}
	if !headerUnsigned(d.Parameter) {
		return bad()
	}
	input, e := headerLiteral(d.Input)
	if e != nil {
		return "", e
	}
	tags := []string{"unit", "bool", "int", "var", "let", "if", "prim", "emit"}
	ops := []string{"add", "sub", "mul", "div", "neg", "lt", "le", "gt", "ge", "not"}
	rows := make([]string, len(d.Rows))
	for i, r := range d.Rows {
		tag := headerIndex(tags, r.Tag)
		op := headerIndex(ops, r.Op)
		if tag < 0 || (op < 0 && r.Op != "none") || !headerUnsigned(r.ID) || !headerUnsigned(r.Binding) || (r.Label != "" && !loweringLabel.MatchString(r.Label)) {
			return bad()
		}
		literal, e := headerLiteral(r.Literal)
		if e != nil {
			return "", e
		}
		children := [3]int{-1, -1, -1}
		if len(r.Children) > 3 {
			return bad()
		}
		copy(children[:], r.Children)
		// The allowed ASCII label domain has identical Go/JSON.stringify quoting.
		rows[i] = fmt.Sprintf("{%d,UINT64_C(%s),UINT64_C(%s),%d,%s,%s,%d,{%d,%d,%d}}", tag, r.ID, r.Binding, op, literal, strconv.Quote(r.Label), len(r.Children), children[0], children[1], children[2])
	}
	return fmt.Sprintf("/* Validated artifact DATA ONLY, not precomputed transitions. */\n#define NA_ARTIFACT_SHA256 %s\n#define NA_INPUT_SHA256 %s\nstatic const struct na_node na_nodes[]={\n%s\n};\nstatic const unsigned na_node_count=%d;\nstatic const unsigned na_root=%d;\nstatic const uint64_t na_parameter=UINT64_C(%s);\nstatic const struct na_value na_input=%s;\n", strconv.Quote(d.Artifact), strconv.Quote(d.InputHash), strings.Join(rows, ",\n"), len(d.Rows), d.Root, d.Parameter, input), nil
}

func headerIndex(values []string, s string) int {
	for i, v := range values {
		if v == s {
			return i
		}
	}
	return -1
}
func headerUnsigned(s string) bool {
	n, e := strconv.ParseUint(s, 10, 64)
	return e == nil && strconv.FormatUint(n, 10) == s
}
func headerLiteral(v []any) (string, error) {
	bad := func() (string, error) { return "", fmt.Errorf("NativeAdmissionHeaderData") }
	if len(v) == 1 && v[0] == "unit" {
		return "{0,0}", nil
	}
	if len(v) != 2 {
		return bad()
	}
	switch v[0] {
	case "bool":
		b, ok := v[1].(bool)
		if !ok {
			return bad()
		}
		if b {
			return "{1,1}", nil
		}
		return "{1,0}", nil
	case "int":
		s, ok := v[1].(string)
		if !ok {
			return bad()
		}
		n, e := strconv.ParseInt(s, 10, 64)
		if e != nil || strconv.FormatInt(n, 10) != s {
			return bad()
		}
		if n == -1<<63 {
			return "{2,(-INT64_C(9223372036854775807)-1)}", nil
		}
		if n < 0 {
			return fmt.Sprintf("{2,(-INT64_C(%d))}", -n), nil
		}
		return fmt.Sprintf("{2,INT64_C(%d)}", n), nil
	}
	return bad()
}
