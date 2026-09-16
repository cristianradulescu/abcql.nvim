package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunExecInvalidJSON(t *testing.T) {
	in := strings.NewReader("not json")
	var out bytes.Buffer

	code := runExec(in, &out)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}

	var resp Response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp.Error == "" {
		t.Fatal("expected an error message, got none")
	}
}

func TestRunExecUnsupportedEngine(t *testing.T) {
	in := strings.NewReader(`{"engine":"postgres","sql":"select 1"}`)
	var out bytes.Buffer

	code := runExec(in, &out)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}

	var resp Response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if !strings.Contains(resp.Error, "postgres") {
		t.Fatalf("error = %q, want it to mention the unsupported engine", resp.Error)
	}
}

func TestRunExecConnectionFailure(t *testing.T) {
	// No server listening on this port: exercises the "backend always emits
	// a single JSON object, even on failure" contract without needing a
	// real MySQL server.
	in := strings.NewReader(`{"host":"127.0.0.1","port":1,"user":"root","database":"x","sql":"select 1","timeout_ms":500}`)
	var out bytes.Buffer

	code := runExec(in, &out)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}

	var resp Response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp.Error == "" {
		t.Fatal("expected a connection error, got none")
	}
}
