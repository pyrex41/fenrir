package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const maxPayload = 65500

// canonical matches the ASCII, sorted-key transport. Numeric tokens are never
// admitted on this wire; model integers and counters are decimal strings.
func canonical(v any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	out := bytes.TrimSuffix(b.Bytes(), []byte{'\n'})
	for _, c := range out {
		if c > 127 {
			return nil, fmt.Errorf("PayloadEncoding")
		}
	}
	return out, nil
}

func decodeRecord(body []byte) (map[string]any, error) {
	// Token traversal detects duplicate keys before the ordinary JSON decoder
	// could silently discard them. Also reject every numeric token.
	d := json.NewDecoder(bytes.NewReader(body))
	d.UseNumber()
	var parse func(int) (any, error)
	parse = func(depth int) (any, error) {
		if depth > 128 {
			return nil, fmt.Errorf("PayloadDepth")
		}
		t, err := d.Token()
		if err != nil {
			return nil, err
		}
		switch t := t.(type) {
		case json.Number:
			return nil, fmt.Errorf("NumericToken")
		case json.Delim:
			switch t {
			case '{':
				obj := map[string]any{}
				for d.More() {
					k, err := d.Token()
					if err != nil {
						return nil, err
					}
					key, ok := k.(string)
					if !ok {
						return nil, fmt.Errorf("RecordShape")
					}
					if _, exists := obj[key]; exists {
						return nil, fmt.Errorf("DuplicateKey")
					}
					v, err := parse(depth + 1)
					if err != nil {
						return nil, err
					}
					obj[key] = v
				}
				end, err := d.Token()
				if err != nil || end != json.Delim('}') {
					return nil, fmt.Errorf("PayloadEncoding")
				}
				return obj, nil
			case '[':
				arr := []any{}
				for d.More() {
					v, err := parse(depth + 1)
					if err != nil {
						return nil, err
					}
					arr = append(arr, v)
				}
				end, err := d.Token()
				if err != nil || end != json.Delim(']') {
					return nil, fmt.Errorf("PayloadEncoding")
				}
				return arr, nil
			}
			return nil, fmt.Errorf("PayloadEncoding")
		default:
			return t, nil
		}
	}
	v, err := parse(0)
	if err != nil {
		return nil, err
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, fmt.Errorf("ExtraPayload")
	}
	row, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("RecordShape")
	}
	c, err := canonical(row)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(c, body) {
		return nil, fmt.Errorf("NoncanonicalPayload")
	}
	return row, nil
}

func frame(row map[string]any) ([]byte, error) {
	b, err := canonical(row)
	if err != nil {
		return nil, err
	}
	if len(b) < 1 || len(b) > maxPayload {
		return nil, fmt.Errorf("PayloadLimit")
	}
	return append(append([]byte(fmt.Sprintf("FGCTL/1 %d\n", len(b))), b...), '\n'), nil
}

// Read one bounded frame at a time: a malformed suffix never erases a valid
// prefix, irrespective of pipe fragmentation or coalescing.
func readFrame(r *bufio.Reader) (map[string]any, error) {
	var header []byte
	for {
		c, err := r.ReadByte()
		if err != nil {
			if err == io.EOF && len(header) > 0 {
				err = fmt.Errorf("TruncatedFrame")
			}
			return nil, err
		}
		if c == '\n' {
			break
		}
		header = append(header, c)
		if len(header) > 31 {
			return nil, fmt.Errorf("HeaderLimit")
		}
	}
	h := string(header)
	if !strings.HasPrefix(h, "FGCTL/1 ") {
		return nil, fmt.Errorf("MalformedHeader")
	}
	s := strings.TrimPrefix(h, "FGCTL/1 ")
	if len(s) < 1 || len(s) > 5 || s[0] == '0' {
		return nil, fmt.Errorf("MalformedHeader")
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return nil, fmt.Errorf("MalformedHeader")
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil || n > maxPayload {
		return nil, fmt.Errorf("PayloadLimit")
	}
	b := make([]byte, n+1)
	if _, err = io.ReadFull(r, b); err != nil {
		return nil, fmt.Errorf("TruncatedFrame")
	}
	if b[n] != '\n' {
		return nil, fmt.Errorf("PayloadDelimiter")
	}
	return decodeRecord(b[:n])
}
