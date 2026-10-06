package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The host translates data and decodes observations only. All transitions are
// evaluated by the existing independent Shen model, never implemented here.
func shenExpr(v any) (string, error) {
	a, ok := v.([]any)
	if !ok || len(a) < 2 {
		return "", fmt.Errorf("ExpressionShape")
	}
	tag, ok := a[0].(string)
	if !ok {
		return "", fmt.Errorf("ExpressionTag")
	}
	id, ok := a[1].(string)
	if !ok || !decimal(id) {
		return "", fmt.Errorf("NodeID")
	}
	var rest []string
	atom := func(v any) (string, error) {
		s, ok := v.(string)
		if !ok {
			return "", fmt.Errorf("ExpressionAtom")
		}
		return s, nil
	}
	switch tag {
	case "unit":
		if len(a) != 2 {
			return "", fmt.Errorf("ExpressionArity")
		}
	case "int", "var":
		if len(a) != 3 {
			return "", fmt.Errorf("ExpressionArity")
		}
		s, e := atom(a[2])
		if e != nil {
			return "", e
		}
		rest = append(rest, s)
	case "bool":
		if len(a) != 3 {
			return "", fmt.Errorf("ExpressionArity")
		}
		b, ok := a[2].(bool)
		if !ok {
			return "", fmt.Errorf("BoolShape")
		}
		rest = append(rest, strconv.FormatBool(b))
	case "let", "emit", "prim":
		if len(a) < 4 {
			return "", fmt.Errorf("ExpressionArity")
		}
		s, e := atom(a[2])
		if e != nil {
			return "", e
		}
		if tag == "emit" {
			if !identifier(s) {
				return "", fmt.Errorf("LabelScope")
			}
			b, _ := json.Marshal(s)
			s = string(b)
		}
		if tag == "prim" {
			switch s {
			case "add", "sub", "mul", "div", "neg", "lt", "le", "gt", "ge", "not":
			default:
				return "", fmt.Errorf("PrimitiveScope")
			}
		}
		rest = append(rest, s)
		for _, child := range a[3:] {
			s, e := shenExpr(child)
			if e != nil {
				return "", e
			}
			rest = append(rest, s)
		}
	case "if":
		if len(a) != 5 {
			return "", fmt.Errorf("ExpressionArity")
		}
		for _, child := range a[2:] {
			s, e := shenExpr(child)
			if e != nil {
				return "", e
			}
			rest = append(rest, s)
		}
	default:
		return "", fmt.Errorf("ExpressionScope")
	}
	suffix := ""
	if len(rest) > 0 {
		suffix = " " + strings.Join(rest, " ")
	}
	return "[" + tag + " " + id + suffix + "]", nil
}
func decimal(s string) bool {
	if s == "0" {
		return true
	}
	if len(s) == 0 || s[0] == '0' {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
func identifier(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i, c := range s {
		if !(c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func parseShen(s string) (any, error) {
	i := 0
	var parse func(int) (any, error)
	parse = func(depth int) (any, error) {
		if depth > 128 {
			return nil, fmt.Errorf("ShenDepth")
		}
		for i < len(s) && strings.ContainsRune(" \t\r\n", rune(s[i])) {
			i++
		}
		if i >= len(s) {
			return nil, fmt.Errorf("ShenTruncated")
		}
		if s[i] == '[' {
			i++
			a := []any{}
			for {
				for i < len(s) && strings.ContainsRune(" \t\r\n", rune(s[i])) {
					i++
				}
				if i >= len(s) {
					return nil, fmt.Errorf("ShenUnclosed")
				}
				if s[i] == ']' {
					i++
					return a, nil
				}
				v, e := parse(depth + 1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
		}
		if s[i] == ']' {
			return nil, fmt.Errorf("ShenClose")
		}
		start := i
		if s[i] == '"' {
			i++
			for i < len(s) {
				if s[i] == '\\' {
					i += 2
					continue
				}
				if s[i] == '"' {
					i++
					var v string
					if e := json.Unmarshal([]byte(s[start:i]), &v); e != nil {
						return nil, e
					}
					return v, nil
				}
				i++
			}
			return nil, fmt.Errorf("ShenString")
		}
		for i < len(s) && !strings.ContainsRune(" []\t\r\n", rune(s[i])) {
			i++
		}
		return s[start:i], nil
	}
	v, e := parse(0)
	if e != nil {
		return nil, e
	}
	if strings.TrimSpace(s[i:]) != "" {
		return nil, fmt.Errorf("ShenExtra")
	}
	return v, nil
}
func list(v any, n int) ([]any, error) {
	a, ok := v.([]any)
	if !ok || (n >= 0 && len(a) != n) {
		return nil, fmt.Errorf("ShenListShape")
	}
	return a, nil
}
func symbol(v any) (string, error) {
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("ShenSymbol")
	}
	return s, nil
}
func mapped(v any, m map[string]string) (string, error) {
	s, e := symbol(v)
	if e != nil {
		return "", e
	}
	r, ok := m[s]
	if !ok {
		return "", fmt.Errorf("ShenUnknownSymbol: %s", s)
	}
	return r, nil
}
func modelValue(v any) (any, error) {
	a, e := list(v, -1)
	if e != nil || len(a) == 0 {
		return nil, fmt.Errorf("ShenValue")
	}
	switch a[0] {
	case "unit":
		if len(a) == 1 {
			return a, nil
		}
	case "int":
		if len(a) == 2 {
			s, e := symbol(a[1])
			if e == nil {
				if _, e = strconv.ParseInt(s, 10, 64); e == nil {
					return a, nil
				}
			}
		}
	case "bool":
		if len(a) == 2 && (a[1] == "true" || a[1] == "false") {
			return []any{"bool", a[1] == "true"}, nil
		}
	}
	return nil, fmt.Errorf("ShenValue")
}
func modelOutcome(v any) (any, error) {
	a, e := list(v, 2)
	if e != nil {
		return nil, e
	}
	if a[0] == "ok" {
		v, e := modelValue(a[1])
		return []any{"Ok", v}, e
	}
	if a[0] != "trap" {
		return nil, fmt.Errorf("ShenOutcome")
	}
	s, e := mapped(a[1], map[string]string{"div-zero": "DivZero", "overflow": "Overflow"})
	return []any{"Trap", s}, e
}
func modelEvent(v any) (any, error) {
	a, e := list(v, -1)
	if e != nil || len(a) < 1 {
		return nil, fmt.Errorf("ShenEvent")
	}
	row := map[string]any{"task": "0"}
	switch a[0] {
	case "scope-exit", "task-termination":
		if len(a) != 2 {
			return nil, fmt.Errorf("ShenEventArity")
		}
		o, e := modelOutcome(a[1])
		if e != nil {
			return nil, e
		}
		row["outcome"] = o
		if a[0] == "scope-exit" {
			row["kind"] = "ScopeExit"
			row["scope"] = "0"
		} else {
			row["kind"] = "TaskTermination"
		}
	case "invoke", "emit":
		if len(a) != 4 {
			return nil, fmt.Errorf("ShenEventArity")
		}
		node, e := symbol(a[1])
		if e != nil || !decimal(node) {
			return nil, fmt.Errorf("ShenEventNode")
		}
		label, e := symbol(a[2])
		if e != nil {
			return nil, e
		}
		v, e := modelValue(a[3])
		if e != nil {
			return nil, e
		}
		row["node"] = node
		row["label"] = label
		row["value"] = v
		if a[0] == "invoke" {
			row["kind"] = "Invoke"
			row["operation"] = "emit"
		} else {
			row["kind"] = "Emit"
		}
	case "commit":
		if len(a) != 3 {
			return nil, fmt.Errorf("ShenEventArity")
		}
		node, e := symbol(a[1])
		if e != nil || !decimal(node) {
			return nil, fmt.Errorf("ShenEventNode")
		}
		v, e := modelValue(a[2])
		if e != nil {
			return nil, e
		}
		row["kind"] = "Commit"
		row["node"] = node
		row["operation"] = "emit"
		row["value"] = v
	default:
		return nil, fmt.Errorf("ShenEventKind")
	}
	return row, nil
}
func normalizeSample(v any, epoch int) (map[string]any, error) {
	a, e := list(v, 5)
	if e != nil || a[0] != "sample" {
		return nil, fmt.Errorf("ShenSample")
	}
	site, e := list(a[1], 3)
	if e != nil {
		return nil, e
	}
	key, e := symbol(site[0])
	if e != nil {
		return nil, e
	}
	var loc string
	if key == "node" {
		loc, e = symbol(site[1])
		if e == nil && !decimal(loc) {
			e = fmt.Errorf("ShenSiteNode")
		}
	} else if key == "machine" {
		loc, e = mapped(site[1], map[string]string{"root-join-entry": "RootJoinEntry", "join": "Join", "terminate": "Terminate"})
	} else {
		return nil, fmt.Errorf("ShenSite")
	}
	if e != nil {
		return nil, e
	}
	rule, e := mapped(site[2], map[string]string{"dispatch": "Dispatch", "ready": "Ready", "collect-return": "CollectReturn", "let-return": "LetReturn", "if-return": "IfReturn", "unwind-frame": "UnwindFrame", "value": "Value", "unwind": "Unwind", "join": "Join", "terminate": "Terminate"})
	if e != nil {
		return nil, e
	}
	after, e := mapped(a[2], map[string]string{"eval": "Eval", "value": "Value", "ready": "Ready", "unwind": "Unwind", "join": "Join", "terminate": "Terminate", "terminal": "Terminal"})
	if e != nil {
		return nil, e
	}
	depth, e := symbol(a[3])
	if e != nil || !decimal(depth) {
		return nil, fmt.Errorf("ShenDepthValue")
	}
	events, e := list(a[4], -1)
	if e != nil {
		return nil, e
	}
	rows := []any{}
	for _, v := range events {
		r, e := modelEvent(v)
		if e != nil {
			return nil, e
		}
		rows = append(rows, r)
	}
	return map[string]any{"epoch": strconv.Itoa(epoch), "site": map[string]any{key: loc, "rule": rule}, "after": after, "depth": depth, "events": rows}, nil
}

type referenceResult struct {
	Steps     []map[string]any `json:"steps"`
	Execution string           `json:"execution"`
	Outcome   any              `json:"outcome"`
	Command   []string         `json:"command"`
	Stdout    string           `json:"stdout"`
	Stderr    string           `json:"stderr"`
}

func reference(root, executable string, artifact map[string]any, input any, fuel int) (referenceResult, error) {
	r := referenceResult{Steps: []map[string]any{}}
	if fuel < 0 || fuel > 200 {
		return r, fmt.Errorf("FuelBounds")
	}
	fns, e := list(artifact["functions"], 1)
	if e != nil {
		return r, e
	}
	fn, ok := fns[0].(map[string]any)
	if !ok {
		return r, fmt.Errorf("FunctionShape")
	}
	param, e := symbol(fn["parameter_id"])
	if e != nil || !decimal(param) {
		return r, fmt.Errorf("ParameterScope")
	}
	body, e := shenExpr(fn["body"])
	if e != nil {
		return r, e
	}
	a, e := list(input, -1)
	if e != nil || len(a) == 0 {
		return r, fmt.Errorf("InputShape")
	}
	val := ""
	switch a[0] {
	case "unit":
		if len(a) == 1 {
			val = "[unit]"
		}
	case "bool":
		if len(a) == 2 {
			b, ok := a[1].(bool)
			if ok {
				val = "[bool " + strconv.FormatBool(b) + "]"
			}
		}
	case "int":
		if len(a) == 2 {
			s, e := symbol(a[1])
			if e == nil {
				if _, e = strconv.ParseInt(s, 10, 64); e == nil {
					val = "[int " + s + "]"
				}
			}
		}
	}
	if val == "" {
		return r, fmt.Errorf("InputShape")
	}
	initial := "[state [eval " + body + "] [[" + param + " " + val + "]] []]"
	cmd := []string{executable, "eval", "-l", filepath.Join(root, "models/tc0/arithmetic.shen"), "-l", filepath.Join(root, "models/tc0/expression-machine.shen"), "-e", "(set na.state " + initial + ")"}
	terminal := "(= (hd (hd (tl (value na.state)))) terminal)"
	for i := 0; i < fuel; i++ {
		cmd = append(cmd, "-e", "(if "+terminal+" na.done (tc0.demo.sample (value na.state)))", "-e", "(if "+terminal+" na.done (set na.state (hd (tl (tc0.demo.step (value na.state))))))")
	}
	cmd = append(cmd, "-e", "(tc0.demo.run (value na.state) 0)")
	out, e := synchronous(root, cmd, 60*time.Second)
	r.Command = cmd
	r.Stdout = out.Stdout
	r.Stderr = out.Stderr
	if e != nil {
		return r, e
	}
	endings := 0
	for _, line := range strings.Split(out.Stdout, "\n") {
		if strings.HasPrefix(line, "[sample ") {
			v, e := parseShen(line)
			if e != nil {
				return r, e
			}
			s, e := normalizeSample(v, len(r.Steps))
			if e != nil {
				return r, e
			}
			r.Steps = append(r.Steps, s)
		} else if strings.HasPrefix(line, "[completed ") || strings.HasPrefix(line, "[budget-exhausted ") {
			endings++
			v, e := parseShen(line)
			if e != nil {
				return r, e
			}
			a, e := list(v, -1)
			if e != nil || len(a) < 2 {
				return r, fmt.Errorf("ShenEnding")
			}
			if a[0] == "completed" {
				r.Execution = "Completed"
				r.Outcome, e = modelOutcome(a[1])
				if e != nil {
					return r, e
				}
			} else {
				r.Execution = "BudgetExhausted"
			}
		}
	}
	if endings != 1 || len(r.Steps) > fuel || r.Execution == "BudgetExhausted" && len(r.Steps) != fuel {
		return r, fmt.Errorf("ShenFramingCount")
	}
	return r, nil
}
