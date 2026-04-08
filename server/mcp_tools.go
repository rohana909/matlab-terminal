// Copyright 2026 The MathWorks, Inc.

package main

import (
	"context"
	"fmt"
	"time"
)

// registerTools defines all MCP tools backed by the given MATLAB client.
func registerTools(client MATLABClient) []MCPTool {
	ctx := context.Background()

	return []MCPTool{
		{
			Name:        "evaluate_matlab_code",
			Description: "Execute MATLAB code in the running MATLAB desktop session and return the output. The code runs in the live session with full access to the workspace, editor, figures, path, and all desktop state. Use this for running commands, creating variables, plotting, and any MATLAB operation.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"code": map[string]any{
						"type":        "string",
						"description": "MATLAB code to execute",
					},
				},
				"required": []string{"code"},
			},
			Handler: func(params map[string]any) MCPToolResult {
				code, _ := params["code"].(string)
				if code == "" {
					return errorResult("code is required")
				}
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "run_matlab_file",
			Description: "Run a MATLAB .m script or function file by path. The file executes in the running MATLAB desktop session.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"file": map[string]any{
						"type":        "string",
						"description": "Absolute or relative path to the .m file",
					},
				},
				"required": []string{"file"},
			},
			Handler: func(params map[string]any) MCPToolResult {
				file, _ := params["file"].(string)
				if file == "" {
					return errorResult("file is required")
				}
				code := fmt.Sprintf("run('%s')", escapeMATLAB(file))
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "check_matlab_code",
			Description: "Run static code analysis (checkcode/mlint) on MATLAB code and return warnings and suggestions.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"file": map[string]any{
						"type":        "string",
						"description": "Path to the .m file to analyze",
					},
				},
				"required": []string{"file"},
			},
			Handler: func(params map[string]any) MCPToolResult {
				file, _ := params["file"].(string)
				if file == "" {
					return errorResult("file is required")
				}
				code := fmt.Sprintf("disp(evalc('checkcode(''%s'')'))", escapeMATLAB(file))
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "matlab_editor_list",
			Description: "List all files currently open in the MATLAB editor. Returns file names, paths, and modification status.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
			Handler: func(params map[string]any) MCPToolResult {
				code := `docs = matlab.desktop.editor.getAll;
result = struct('files', {{}});
for i = 1:numel(docs)
    result.files{end+1} = struct('filename', docs(i).Filename, 'modified', docs(i).Modified);
end
disp(jsonencode(result))`
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "matlab_editor_active",
			Description: "Get the currently active (focused) file in the MATLAB editor, including file path, cursor position, and selected text.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
			Handler: func(params map[string]any) MCPToolResult {
				code := `doc = matlab.desktop.editor.getActive;
if isempty(doc)
    disp(jsonencode(struct('error', 'No active editor document')));
else
    result = struct('filename', doc.Filename, 'modified', doc.Modified, ...
        'selection', doc.Selection, 'selectedText', doc.SelectedText);
    disp(jsonencode(result));
end`
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "matlab_editor_selection",
			Description: "Get the text currently highlighted/selected in the active MATLAB editor. Use this when the user asks about 'this code' or 'the selected code'.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
			Handler: func(params map[string]any) MCPToolResult {
				code := `doc = matlab.desktop.editor.getActive;
if isempty(doc)
    disp('No active editor document');
elseif isempty(doc.SelectedText)
    disp('No text selected');
else
    disp(doc.SelectedText);
end`
				return evalMATLAB(ctx, client, code)
			},
		},
		{
			Name:        "matlab_editor_read",
			Description: "Read the contents of a file open in the MATLAB editor. Reflects unsaved edits (unlike reading from disk). If no name is given, reads the active file. Supports partial name matching.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"name": map[string]any{
						"type":        "string",
						"description": "File name or partial path to match. If omitted, reads the active file.",
					},
				},
			},
			Handler: func(params map[string]any) MCPToolResult {
				name, _ := params["name"].(string)
				var code string
				if name == "" {
					code = `doc = matlab.desktop.editor.getActive;
if isempty(doc)
    disp('No active editor document');
else
    fprintf('File: %s\n\n', doc.Filename);
    disp(doc.Text);
end`
				} else {
					code = fmt.Sprintf(`docs = matlab.desktop.editor.getAll;
target = '%s';
found = false;
for i = 1:numel(docs)
    if contains(docs(i).Filename, target)
        fprintf('File: %%s\n\n', docs(i).Filename);
        disp(docs(i).Text);
        found = true;
        break;
    end
end
if ~found
    fprintf('No open file matching "%%s"\n', target);
end`, escapeMATLAB(name))
				}
				return evalMATLAB(ctx, client, code)
			},
		},
	}
}

// evalMATLAB runs code via the client and returns an MCP tool result.
func evalMATLAB(ctx context.Context, client MATLABClient, code string) MCPToolResult {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	output, err := client.Eval(ctx, code)
	if err != nil {
		return errorResult(fmt.Sprintf("MATLAB execution failed: %v", err))
	}

	return MCPToolResult{
		Content: []MCPContent{{Type: "text", Text: output}},
	}
}

// errorResult creates an MCP error result with the given message.
func errorResult(msg string) MCPToolResult {
	return MCPToolResult{
		Content: []MCPContent{{Type: "text", Text: msg}},
		IsError: true,
	}
}

// escapeMATLAB escapes single quotes for use in MATLAB string literals.
func escapeMATLAB(s string) string {
	result := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\'' {
			result = append(result, '\'', '\'')
		} else {
			result = append(result, s[i])
		}
	}
	return string(result)
}

