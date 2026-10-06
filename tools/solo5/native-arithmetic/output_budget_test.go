package main

import (
	"strings"
	"testing"
)

func TestCombinedOutputBudget(t *testing.T) {
	out, errout := newOutputBuffers()
	if _, e := out.Write([]byte(strings.Repeat("a", outputLimit/2))); e != nil {
		t.Fatal(e)
	}
	if _, e := errout.Write([]byte(strings.Repeat("b", outputLimit/2))); e != nil {
		t.Fatal(e)
	}
	if _, e := out.Write([]byte("c")); e == nil {
		t.Fatal("combined stdout/stderr cap bypassed")
	}
	s, exceeded := out.snapshot()
	se, _ := errout.snapshot()
	if !exceeded || len(s)+len(se) != outputLimit {
		t.Fatal("bounded prefix not retained")
	}
}
