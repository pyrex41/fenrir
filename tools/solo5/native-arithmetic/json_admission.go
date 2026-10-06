package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"syscall"
)

// Host reports allow JSON numbers (e.g. diagnostics), unlike the FGCTL wire.
// Semantic artifact/input shapes remain the existing Node validator's domain.
const maxHostJSONBytes = 4 * 1024 * 1024
const maxHostJSONDepth = 128
const maxHostJSONValues = 100000

func readHostJSON(path string) ([]byte, error) {
	f, e := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("HostJSONRegularFileRequired")
	}
	b, e := io.ReadAll(io.LimitReader(f, maxHostJSONBytes+1))
	if e != nil {
		return nil, e
	}
	if len(b) > maxHostJSONBytes {
		return nil, fmt.Errorf("HostJSONByteLimit")
	}
	return b, nil
}

// Walk before typed decoding: encoding/json otherwise silently overwrites
// duplicates, ignores unknown fields and accepts null for scalar targets.
func hostJSONValue(b []byte) (any, error) {
	if len(b) > maxHostJSONBytes {
		return nil, fmt.Errorf("HostJSONByteLimit")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	count := 0
	var parse func(int) (any, error)
	parse = func(depth int) (any, error) {
		count++
		if depth > maxHostJSONDepth {
			return nil, fmt.Errorf("HostJSONDepth")
		}
		if count > maxHostJSONValues {
			return nil, fmt.Errorf("HostJSONValueLimit")
		}
		t, e := d.Token()
		if e != nil {
			return nil, e
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return t, nil
		}
		switch delim {
		case '{':
			m := map[string]any{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return nil, e
				}
				key, ok := k.(string)
				if !ok {
					return nil, fmt.Errorf("HostJSONKey")
				}
				if _, ok = m[key]; ok {
					return nil, fmt.Errorf("HostJSONDuplicateKey: %s", key)
				}
				v, e := parse(depth + 1)
				if e != nil {
					return nil, e
				}
				m[key] = v
			}
			end, e := d.Token()
			if e != nil || end != json.Delim('}') {
				return nil, fmt.Errorf("HostJSONObject")
			}
			return m, nil
		case '[':
			a := []any{}
			for d.More() {
				v, e := parse(depth + 1)
				if e != nil {
					return nil, e
				}
				a = append(a, v)
			}
			end, e := d.Token()
			if e != nil || end != json.Delim(']') {
				return nil, fmt.Errorf("HostJSONArray")
			}
			return a, nil
		default:
			return nil, fmt.Errorf("HostJSONDelimiter")
		}
	}
	v, e := parse(0)
	if e != nil {
		return nil, e
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, fmt.Errorf("HostJSONTrailingData")
	}
	return v, nil
}

func hostJSONShape(v any, t reflect.Type, path string) error {
	if t.Kind() == reflect.Interface {
		return nil
	}
	if v == nil {
		// Existing traces/choices and error diagnostics serialize nil containers.
		if t.Kind() == reflect.Map || t.Kind() == reflect.Slice || t.Kind() == reflect.Pointer {
			return nil
		}
		return fmt.Errorf("HostJSONNullScalar: %s", path)
	}
	if t.Kind() == reflect.Pointer {
		return hostJSONShape(v, t.Elem(), path)
	}
	switch t.Kind() {
	case reflect.Struct:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("HostJSONObjectRequired: %s", path)
		}
		fields := map[string]reflect.Type{}
		for i := 0; i < t.NumField(); i++ {
			f := t.Field(i)
			if !f.IsExported() {
				continue
			}
			name := strings.Split(f.Tag.Get("json"), ",")[0]
			if name == "-" {
				continue
			}
			if name == "" {
				name = f.Name
			}
			fields[name] = f.Type
		}
		for k := range m {
			if _, ok := fields[k]; !ok {
				return fmt.Errorf("HostJSONUnknownField: %s.%s", path, k)
			}
		}
		for k, ft := range fields {
			x, ok := m[k]
			if !ok {
				return fmt.Errorf("HostJSONMissingField: %s.%s", path, k)
			}
			if e := hostJSONShape(x, ft, path+"."+k); e != nil {
				return e
			}
		}
	case reflect.Map:
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("HostJSONMapRequired: %s", path)
		}
		for k, x := range m {
			if e := hostJSONShape(x, t.Elem(), path+"."+k); e != nil {
				return e
			}
		}
	case reflect.Slice, reflect.Array:
		a, ok := v.([]any)
		if !ok {
			return fmt.Errorf("HostJSONArrayRequired: %s", path)
		}
		for _, x := range a {
			if e := hostJSONShape(x, t.Elem(), path+"[]"); e != nil {
				return e
			}
		}
	case reflect.String:
		if _, ok := v.(string); !ok {
			return fmt.Errorf("HostJSONStringRequired: %s", path)
		}
	case reflect.Bool:
		if _, ok := v.(bool); !ok {
			return fmt.Errorf("HostJSONBoolRequired: %s", path)
		}
	default:
		if _, ok := v.(json.Number); !ok {
			return fmt.Errorf("HostJSONNumberRequired: %s", path)
		}
	}
	return nil
}

func loadJSON(path string, target any) error {
	b, e := readHostJSON(path)
	if e != nil {
		return e
	}
	return decodeHostJSON(b, target)
}

func decodeHostJSON(b []byte, target any) error {
	v, e := hostJSONValue(b)
	if e != nil {
		return e
	}
	t := reflect.TypeOf(target)
	if t == nil || t.Kind() != reflect.Pointer {
		return fmt.Errorf("HostJSONTarget")
	}
	if e = hostJSONShape(v, t.Elem(), "$"); e != nil {
		return e
	}
	// Integer ranges and fractional integer rejection are enforced here. The
	// shape walk uses exact field names (including case), unlike Unmarshal.
	return json.Unmarshal(b, target)
}
