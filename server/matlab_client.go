// Copyright 2026 The MathWorks, Inc.

package main

import "context"

// MATLABClient abstracts communication with a MATLAB session.
// The ECClient implementation talks directly to the Embedded Connector.
// This interface exists so the backend can be swapped later (e.g., to
// delegate to the official matlab-mcp-core-server).
type MATLABClient interface {
	// Eval sends MATLAB code for execution and returns console output.
	Eval(ctx context.Context, code string) (string, error)

	// FEval calls a MATLAB function by name with the given arguments.
	// nargout specifies the number of expected return values.
	FEval(ctx context.Context, fn string, args []any, nargout int) ([]any, error)

	// Ping checks whether MATLAB is alive and responsive.
	Ping(ctx context.Context) bool
}
