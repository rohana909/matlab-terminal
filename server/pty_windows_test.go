// Copyright 2026 The MathWorks, Inc.

//go:build windows

package main

import (
	"testing"
)

func TestWindowsPTY_DoubleClose(t *testing.T) {
	// Before the fix, calling Close() followed by Kill() (or multiple
	// Close calls) would double-free the ConPTY handle, crashing the
	// process with STATUS_HEAP_CORRUPTION (0xC0000374).
	p, err := startPTY("cmd.exe", 80, 24)
	if err != nil {
		t.Fatalf("startPTY failed: %v", err)
	}

	// First close should succeed.
	if err := p.Close(); err != nil {
		t.Fatalf("first Close failed: %v", err)
	}
	// Kill after Close should be a no-op, not crash.
	if err := p.Kill(); err != nil {
		t.Fatalf("Kill after Close failed: %v", err)
	}
	// Repeated Close should also be safe.
	if err := p.Close(); err != nil {
		t.Fatalf("second Close failed: %v", err)
	}
}
