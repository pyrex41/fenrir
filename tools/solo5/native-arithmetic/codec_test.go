package main

import (
	"bufio"
	"bytes"
	"io"
	"strings"
	"testing"
	"time"
)

type byteReader struct{ r io.Reader }

func (r byteReader) Read(p []byte) (int, error) {
	if len(p) > 1 {
		p = p[:1]
	}
	return r.r.Read(p)
}

func TestCanonicalWire(t *testing.T) {
	row := map[string]any{"z": []any{"<>&", true}, "a": "0"}
	want := `{"a":"0","z":["<>&",true]}`
	b, err := canonical(row)
	if err != nil || string(b) != want {
		t.Fatalf("%s %v", b, err)
	}
	f, err := frame(row)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range []io.Reader{bytes.NewReader(f), byteReader{bytes.NewReader(f)}} {
		got, err := readFrame(bufio.NewReader(r))
		if err != nil {
			t.Fatal(err)
		}
		b, _ = canonical(got)
		if string(b) != want {
			t.Fatalf("%s", b)
		}
	}
}
func TestClosedPayload(t *testing.T) {
	for _, s := range []string{`{"a":"0","a":"1"}`, `{"a":0}`, `{"a":1.2}`, `{"a":NaN}`, `{"a":"é"}`, `{"a": "0"}`, `[]`, `{"b":"0","a":"0"}`, `{"a":"0"} {}`, `{"a":"\u003c"}`} {
		if _, err := decodeRecord([]byte(s)); err == nil {
			t.Errorf("admitted %s", s)
		}
	}
}
func TestFrameFailuresAndPrefix(t *testing.T) {
	for _, s := range []string{"FGCTL/1 0\n", "FGCTL/1 01\n", "FGCTL/1 65501\n", "FGCTL/1 2\n{}x", "FGCTL/1 3\n{}", "FGCTL/1", strings.Repeat("x", 33)} {
		if _, err := readFrame(bufio.NewReader(strings.NewReader(s))); err == nil {
			t.Errorf("admitted %q", s)
		}
	}
	f, _ := frame(map[string]any{"a": "0"})
	r := bufio.NewReader(bytes.NewReader(append(f, []byte("BAD\n")...)))
	if _, err := readFrame(r); err != nil {
		t.Fatal(err)
	}
	if _, err := readFrame(r); err == nil {
		t.Fatal("bad suffix admitted")
	}
}
func TestOwnedCommand(t *testing.T) {
	r, err := synchronous(".", []string{"sh", "-c", "printf hello; printf diagnostic >&2"}, time.Second)
	if err != nil || r.Stdout != "hello" || r.Stderr != "diagnostic" || r.Exit != 0 {
		t.Fatalf("%+v %v", r, err)
	}
	if _, err = synchronous(".", []string{"sh", "-c", "sleep 5"}, 30*time.Millisecond); err == nil || !strings.Contains(err.Error(), "CommandTimeout") {
		t.Fatalf("%v", err)
	}
	r, err = synchronous(".", []string{"sh", "-c", "exit 7"}, time.Second)
	if err == nil || r.Exit != 7 {
		t.Fatalf("%+v %v", r, err)
	}
}
func TestBoundedOutput(t *testing.T) {
	b := &boundedBuffer{}
	if _, err := b.Write(make([]byte, outputLimit)); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Write([]byte{1}); err == nil {
		t.Fatal("limit not enforced")
	}
	s, exceeded := b.snapshot()
	if len(s) != outputLimit || !exceeded {
		t.Fatal("bound differs")
	}
}
