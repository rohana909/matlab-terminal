// Copyright 2026 The MathWorks, Inc.

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

// MCPServer implements the MCP (Model Context Protocol) over stdio.
// It reads JSON-RPC 2.0 requests from stdin and writes responses to stdout.
type MCPServer struct {
	client MATLABClient
	tools  []MCPTool
	reader *bufio.Reader
	writer io.Writer
}

// MCPTool describes a tool the MCP server exposes to AI agents.
type MCPTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Handler     func(params map[string]any) MCPToolResult `json:"-"`
}

// MCPToolResult is what a tool handler returns.
type MCPToolResult struct {
	Content []MCPContent `json:"content"`
	IsError bool         `json:"isError,omitempty"`
}

// MCPContent is a single content block in a tool result.
type MCPContent struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
	Data string `json:"data,omitempty"`
	Mime string `json:"mimeType,omitempty"`
}

// JSON-RPC types
type jsonrpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonrpcResponse struct {
	JSONRPC string `json:"jsonrpc"`
	ID      any    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   any    `json:"error,omitempty"`
}

type jsonrpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// NewMCPServer creates an MCP server backed by the given MATLAB client.
func NewMCPServer(client MATLABClient) *MCPServer {
	s := &MCPServer{
		client: client,
		reader: bufio.NewReader(os.Stdin),
		writer: os.Stdout,
	}
	s.tools = registerTools(client)
	return s
}

// Run starts the MCP server loop, reading from stdin until EOF.
func (s *MCPServer) Run() error {
	// MCP uses newline-delimited JSON-RPC.
	for {
		line, err := s.reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return fmt.Errorf("read stdin: %w", err)
		}

		var req jsonrpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("invalid JSON-RPC: %v", err)
			continue
		}

		// Notifications (no id) don't get a response.
		if req.ID == nil {
			s.handleNotification(req)
			continue
		}

		resp := s.handleRequest(req)
		s.send(resp)
	}
}

func (s *MCPServer) handleNotification(req jsonrpcRequest) {
	switch req.Method {
	case "notifications/initialized":
		// Client acknowledged initialization — nothing to do.
	default:
		log.Printf("unknown notification: %s", req.Method)
	}
}

func (s *MCPServer) handleRequest(req jsonrpcRequest) jsonrpcResponse {
	switch req.Method {
	case "initialize":
		return s.handleInitialize(req)
	case "tools/list":
		return s.handleToolsList(req)
	case "tools/call":
		return s.handleToolsCall(req)
	default:
		return jsonrpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error: jsonrpcError{
				Code:    -32601,
				Message: fmt.Sprintf("method not found: %s", req.Method),
			},
		}
	}
}

func (s *MCPServer) handleInitialize(req jsonrpcRequest) jsonrpcResponse {
	return jsonrpcResponse{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"protocolVersion": "2024-11-05",
			"capabilities": map[string]any{
				"tools": map[string]any{},
			},
			"serverInfo": map[string]any{
				"name":    "terminal-mcp",
				"version": "0.1.0",
			},
		},
	}
}

func (s *MCPServer) handleToolsList(req jsonrpcRequest) jsonrpcResponse {
	toolDefs := make([]map[string]any, len(s.tools))
	for i, t := range s.tools {
		toolDefs[i] = map[string]any{
			"name":        t.Name,
			"description": t.Description,
			"inputSchema": t.InputSchema,
		}
	}
	return jsonrpcResponse{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"tools": toolDefs,
		},
	}
}

func (s *MCPServer) handleToolsCall(req jsonrpcRequest) jsonrpcResponse {
	var params struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return jsonrpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error: jsonrpcError{
				Code:    -32602,
				Message: fmt.Sprintf("invalid params: %v", err),
			},
		}
	}

	for _, t := range s.tools {
		if t.Name == params.Name {
			result := t.Handler(params.Arguments)
			return jsonrpcResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Result:  result,
			}
		}
	}

	return jsonrpcResponse{
		JSONRPC: "2.0",
		ID:      req.ID,
		Error: jsonrpcError{
			Code:    -32602,
			Message: fmt.Sprintf("unknown tool: %s", params.Name),
		},
	}
}

func (s *MCPServer) send(resp jsonrpcResponse) {
	data, err := json.Marshal(resp)
	if err != nil {
		log.Printf("marshal response: %v", err)
		return
	}
	data = append(data, '\n')
	s.writer.Write(data)
}
