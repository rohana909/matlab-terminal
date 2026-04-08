// Copyright 2026 The MathWorks, Inc.

package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

// envFlags collects repeatable --env KEY=VALUE flags.
type envFlags []string

func (e *envFlags) String() string { return strings.Join(*e, ",") }
func (e *envFlags) Set(v string) error {
	*e = append(*e, v)
	return nil
}

func main() {
	var (
		token       string
		envVars     envFlags
		idleTimeout time.Duration
		readyFile   string
		mcpMode     bool
		ecPort      int
		mwapikey    string
	)

	flag.StringVar(&token, "token", "", "authentication token (required for terminal mode)")
	flag.Var(&envVars, "env", "environment variable in KEY=VALUE format (repeatable)")
	flag.DurationVar(&idleTimeout, "idle-timeout", 30*time.Second, "exit after this duration with no connections")
	flag.StringVar(&readyFile, "ready-file", "", "write PID/PORT to this file on startup (closed immediately)")
	flag.BoolVar(&mcpMode, "mcp", false, "run as MCP server (stdio JSON-RPC)")
	flag.IntVar(&ecPort, "ec-port", 0, "Embedded Connector port (MCP mode)")
	flag.StringVar(&mwapikey, "mwapikey", "", "Embedded Connector API key (MCP mode)")
	flag.Parse()

	// MCP mode: run as an MCP server over stdio, no HTTP/PTY.
	if mcpMode {
		if ecPort == 0 {
			// Fall back to environment variable.
			if v := os.Getenv("MATLAB_EC_PORT"); v != "" {
				fmt.Sscanf(v, "%d", &ecPort)
			}
		}
		if mwapikey == "" {
			mwapikey = os.Getenv("MWAPIKEY")
		}
		if ecPort == 0 || mwapikey == "" {
			log.Fatal("MCP mode requires --ec-port and --mwapikey (or MATLAB_EC_PORT and MWAPIKEY env vars)")
		}
		client := NewECClient(ecPort, mwapikey)
		server := NewMCPServer(client)
		if err := server.Run(); err != nil {
			log.Fatalf("MCP server error: %v", err)
		}
		return
	}

	if token == "" {
		log.Fatal("--token is required")
	}

	// Apply extra environment variables to the current process.
	// Child processes (PTY sessions) inherit them on all platforms.
	for _, e := range envVars {
		if k, v, ok := strings.Cut(e, "="); ok {
			os.Setenv(k, v)
		}
	}
	// Override TERM so PTY sessions get color support (harmless on Windows).
	os.Setenv("TERM", "xterm-256color")

	// Detect default shell (platform-specific).
	shell := defaultShell()

	// Create session manager.
	manager := NewSessionManager(shell)

	// Create HTTP API handler.
	apiHandler := NewAPIHandler(token, manager)

	mux := http.NewServeMux()
	mux.HandleFunc("/api/create", apiHandler.HandleCreate)
	mux.HandleFunc("/api/input", apiHandler.HandleInput)
	mux.HandleFunc("/api/resize", apiHandler.HandleResize)
	mux.HandleFunc("/api/close", apiHandler.HandleClose)
	mux.HandleFunc("/api/poll", apiHandler.HandlePoll)
	mux.HandleFunc("/api/sessions", apiHandler.HandleSessions)
	mux.HandleFunc("/api/scrollback", apiHandler.HandleScrollback)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	port := listener.Addr().(*net.TCPAddr).Port
	fmt.Printf("PID:%d\n", os.Getpid())
	fmt.Printf("PORT:%d\n", port)

	// Write startup info to a ready file if requested.
	// The file is written and closed immediately so the reader is never
	// blocked by a file lock (critical on Windows).
	if readyFile != "" {
		info := fmt.Sprintf("PID:%d\nPORT:%d\n", os.Getpid(), port)
		if err := os.WriteFile(readyFile, []byte(info), 0600); err != nil {
			log.Printf("warning: failed to write ready file: %v", err)
		}
	}

	// Monitor parent PID — exit if parent dies.
	parentPID := os.Getppid()
	go monitorParent(parentPID)

	// Idle timeout based on last API activity.
	go func() {
		time.Sleep(5 * time.Second) // grace period on startup
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if time.Since(apiHandler.LastActivity()) >= idleTimeout {
				log.Println("idle timeout reached, shutting down")
				os.Exit(0)
			}
		}
	}()

	log.Fatal(http.Serve(listener, mux))
}

// monitorParent polls the parent PID and exits if it changes to 1 (init)
// which indicates the original parent has died.
func monitorParent(parentPID int) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		if os.Getppid() != parentPID {
			log.Println("parent process died, shutting down")
			os.Exit(0)
		}
	}
}
