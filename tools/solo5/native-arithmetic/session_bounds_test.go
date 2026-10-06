package main

import (
	"context"
	"testing"
	"time"
)

func TestSessionPrelaunchBoundsAndCancellation(t *testing.T) {
	for _, timeout := range []time.Duration{0, -time.Second, 31 * time.Second} {
		_, e := runSessionContext(context.Background(), "", buildReport{}, nil, referenceResult{}, "", "normal", timeout, nil)
		if e == nil || e.Error() != "SessionBounds" {
			t.Fatalf("timeout %v: %v", timeout, e)
		}
	}
	_, e := runSessionContext(context.Background(), "", buildReport{}, nil, referenceResult{Steps: make([]map[string]any, 201)}, "", "normal", time.Second, nil)
	if e == nil || e.Error() != "SessionBounds" {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, e = runSessionContext(ctx, "", buildReport{}, nil, referenceResult{}, "", "normal", time.Second, nil)
	if e != context.Canceled || sessionStop(ctx) != "HarnessCanceled" {
		t.Fatal(e)
	}
	deadline, stop := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer stop()
	if sessionStop(deadline) != "HarnessTimeout" {
		t.Fatal("deadline misclassified")
	}
}
