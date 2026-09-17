package main

import (
	"encoding/json"
	"testing"
)

func TestRequestPortAcceptsNumberOrString(t *testing.T) {
	cases := []struct {
		name string
		json string
		want flexInt
	}{
		{"numeric", `{"port":3306}`, 3306},
		{"quoted string", `{"port":"33060"}`, 33060},
		{"empty string", `{"port":""}`, 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var req Request
			if err := json.Unmarshal([]byte(tc.json), &req); err != nil {
				t.Fatalf("Unmarshal(%q) error = %v", tc.json, err)
			}
			if req.Port != tc.want {
				t.Errorf("Port = %v, want %v", req.Port, tc.want)
			}
		})
	}
}

func TestRequestPortRejectsNonNumericString(t *testing.T) {
	var req Request
	err := json.Unmarshal([]byte(`{"port":"not-a-number"}`), &req)
	if err == nil {
		t.Fatal("expected an error for a non-numeric port string, got nil")
	}
}

func TestRequestTimeoutMsAcceptsNumberOrString(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"timeout_ms":"5000"}`), &req); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}
	if req.TimeoutMs != 5000 {
		t.Errorf("TimeoutMs = %v, want 5000", req.TimeoutMs)
	}
}

func TestProxyConfigPortAcceptsString(t *testing.T) {
	var req Request
	body := `{"proxy":{"type":"socks5","host":"127.0.0.1","port":"1080"}}`
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}
	if req.Proxy == nil || req.Proxy.Port != 1080 {
		t.Errorf("Proxy.Port = %+v, want 1080", req.Proxy)
	}
}

func TestRequestMaxRows(t *testing.T) {
	var req Request
	if err := json.Unmarshal([]byte(`{"sql":"select 1","max_rows":"250"}`), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if req.MaxRows != 250 {
		t.Errorf("MaxRows = %d, want 250", req.MaxRows)
	}
}
