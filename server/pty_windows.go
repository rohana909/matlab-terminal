// Copyright 2026 The MathWorks, Inc.

//go:build windows

package main

import (
	"context"
	"fmt"
	"sync"

	"github.com/UserExistsError/conpty"
)

type windowsPTY struct {
	cpty   *conpty.ConPty
	mu     sync.Mutex
	closed bool
}

func startPTY(shell string, cols, rows uint16) (ptyProcess, error) {
	cpty, err := conpty.Start(shell, conpty.ConPtyDimensions(int(cols), int(rows)))
	if err != nil {
		return nil, fmt.Errorf("failed to start conpty: %w", err)
	}
	return &windowsPTY{cpty: cpty}, nil
}

func (p *windowsPTY) Read(b []byte) (int, error)  { return p.cpty.Read(b) }
func (p *windowsPTY) Write(b []byte) (int, error) { return p.cpty.Write(b) }

func (p *windowsPTY) Resize(cols, rows uint16) error {
	return p.cpty.Resize(int(cols), int(rows))
}

func (p *windowsPTY) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.closed {
		p.closed = true
		p.cpty.Close()
	}
	return nil
}

func (p *windowsPTY) Kill() error {
	// On Windows, ConPTY has no separate kill — closing the pseudo-console
	// handle terminates the child process. Delegate to Close which is
	// guarded against double-close.
	return p.Close()
}

func (p *windowsPTY) Wait() (int, error) {
	exitCode, err := p.cpty.Wait(context.Background())
	if err != nil {
		return 1, err
	}
	return int(exitCode), nil
}
