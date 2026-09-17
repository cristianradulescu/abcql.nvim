package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// flexInt unmarshals from either a JSON number or a numeric JSON string, so
// hand-written requests (e.g. a quick shell one-liner) can quote port or
// timeout values without abcql-backend rejecting the request outright.
type flexInt int

func (f *flexInt) UnmarshalJSON(data []byte) error {
	var asInt int
	if err := json.Unmarshal(data, &asInt); err == nil {
		*f = flexInt(asInt)
		return nil
	}

	var asString string
	if err := json.Unmarshal(data, &asString); err != nil {
		return fmt.Errorf("expected a number or a numeric string, got %s", data)
	}

	asString = strings.TrimSpace(asString)
	if asString == "" {
		*f = 0
		return nil
	}

	parsed, err := strconv.Atoi(asString)
	if err != nil {
		return fmt.Errorf("expected a number or a numeric string, got %q", asString)
	}
	*f = flexInt(parsed)
	return nil
}

// Request is the JSON object abcql-backend reads from stdin for the "exec" command.
type Request struct {
	Engine    string            `json:"engine"`
	Host      string            `json:"host"`
	Port      flexInt           `json:"port"`
	User      string            `json:"user"`
	Password  string            `json:"password"`
	Database  string            `json:"database"`
	Options   map[string]string `json:"options"`
	Proxy     *ProxyConfig      `json:"proxy"`
	SQL       string            `json:"sql"`
	TimeoutMs flexInt           `json:"timeout_ms"`
	// MaxRows caps the number of rows returned for a result set; 0 means no
	// cap. When the cap is hit, Response.Truncated is set.
	MaxRows flexInt `json:"max_rows"`
}

// ProxyConfig describes a SOCKS proxy to dial the database connection through.
type ProxyConfig struct {
	Type string  `json:"type"`
	Host string  `json:"host"`
	Port flexInt `json:"port"`
}

// Response is the JSON object abcql-backend writes to stdout for the "exec" command.
// On failure, only Error is set and the process exits with a non-zero status.
//
// Headers/Rows/AffectedRows/MatchedRows/ChangedRows/Warnings intentionally
// have no `omitempty`: for a "write" query, Lua's previous mysql-CLI-based
// implementation always included these as explicit (possibly zero) values,
// and downstream code (ui/format.lua, export/*) expects headers/rows to
// always be tables, never absent/null.
type Response struct {
	QueryType    string     `json:"query_type,omitempty"`
	Headers      []string   `json:"headers"`
	Rows         [][]string `json:"rows"`
	RowCount     int        `json:"row_count"`
	AffectedRows int64      `json:"affected_rows"`
	MatchedRows  int64      `json:"matched_rows"`
	ChangedRows  int64      `json:"changed_rows"`
	Warnings     int        `json:"warnings"`
	Truncated    bool       `json:"truncated,omitempty"`
	DurationMs   float64    `json:"duration_ms,omitempty"`
	Error        string     `json:"error,omitempty"`
}
