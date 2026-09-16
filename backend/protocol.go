package main

// Request is the JSON object abcql-backend reads from stdin for the "exec" command.
type Request struct {
	Engine    string            `json:"engine"`
	Host      string            `json:"host"`
	Port      int               `json:"port"`
	User      string            `json:"user"`
	Password  string            `json:"password"`
	Database  string            `json:"database"`
	Options   map[string]string `json:"options"`
	Proxy     *ProxyConfig      `json:"proxy"`
	SQL       string            `json:"sql"`
	TimeoutMs int               `json:"timeout_ms"`
}

// ProxyConfig describes a SOCKS proxy to dial the database connection through.
type ProxyConfig struct {
	Type string `json:"type"`
	Host string `json:"host"`
	Port int    `json:"port"`
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
	DurationMs   float64    `json:"duration_ms,omitempty"`
	Error        string     `json:"error,omitempty"`
}
