package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestDigestRegularFileRequired(t *testing.T) {
	// Opening the FIFO would hang the old whole-file reader. O_RDWR keeps
	// this data-only fixture open without a writer goroutine or child process.
	fifo := filepath.Join(t.TempDir(), "fifo")
	if e := syscall.Mkfifo(fifo, 0600); e != nil {
		t.Fatal(e)
	}
	fd, e := syscall.Open(fifo, syscall.O_RDWR|syscall.O_NONBLOCK, 0)
	if e != nil {
		t.Fatal(e)
	}
	defer syscall.Close(fd)
	// Test a directory first: it must use the typed resource rejection.
	// The old reader fails here, before it can block on the FIFO.
	if _, e := digest(t.TempDir()); e == nil || e.Error() != "DigestRegularFileRequired" {
		t.Fatalf("expected regular-file rejection, got %v", e)
	}
	// The FIFO check is reached only after the directory policy is installed.
	if _, e := digest(fifo); e == nil || e.Error() != "DigestRegularFileRequired" {
		t.Fatalf("expected FIFO rejection, got %v", e)
	}
}

func TestDigestStreamingIdentity(t *testing.T) {
	for _, size := range []int{0, 1, 32767, 32768, 32769, 2*1024*1024 + 1} {
		b := make([]byte, size)
		for i := range b {
			b[i] = byte(i * 31)
		}
		p := filepath.Join(t.TempDir(), "resource")
		if e := os.WriteFile(p, b, 0600); e != nil {
			t.Fatal(e)
		}
		h, e := digest(p)
		if e != nil || h != hashBytes(b) {
			t.Fatalf("size %d: digest %q, error %v", size, h, e)
		}
		link := p + ".link"
		if e := os.Symlink(p, link); e != nil {
			t.Fatal(e)
		}
		if h, e = digest(link); e != nil || h != hashBytes(b) {
			t.Fatalf("regular-file symlink identity changed: %q %v", h, e)
		}
	}
}
