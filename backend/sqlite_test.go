package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sqliteRequest(path, query string) *Request {
	return &Request{Engine: "sqlite", Database: path, SQL: query}
}

func mustExec(t *testing.T, path, query string) *Response {
	t.Helper()
	resp, err := execRequest(sqliteRequest(path, query))
	if err != nil {
		t.Fatalf("execRequest(%q) error = %v", query, err)
	}
	return resp
}

func newSQLiteFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSQLiteRoundTrip(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, data BLOB, born DATE, score REAL)")

	resp := mustExec(t, path, "INSERT INTO t (name, data, born, score) VALUES ('ana', x'00FF', '2024-03-05', 1.5), (NULL, NULL, NULL, NULL)")
	if resp.QueryType != "write" || resp.AffectedRows != 2 {
		t.Fatalf("insert = %+v, want write with 2 affected rows", resp)
	}

	resp = mustExec(t, path, "SELECT id, name, data, born, score, 'x' || name AS expr FROM t ORDER BY id")
	if resp.QueryType != "select" {
		t.Fatalf("query_type = %q, want select", resp.QueryType)
	}
	want := [][]string{
		{"1", "ana", "0x00FF", "2024-03-05", "1.5", "xana"},
		{"2", "NULL", "NULL", "NULL", "NULL", "NULL"},
	}
	if strings.Join(resp.Headers, ",") != "id,name,data,born,score,expr" {
		t.Errorf("headers = %v", resp.Headers)
	}
	for i, row := range want {
		if strings.Join(resp.Rows[i], "|") != strings.Join(row, "|") {
			t.Errorf("row %d = %v, want %v", i, resp.Rows[i], row)
		}
	}
}

func TestSQLiteForeignKeysEnforced(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE a (id INTEGER PRIMARY KEY)")
	mustExec(t, path, "CREATE TABLE b (a_id INTEGER REFERENCES a(id))")
	if _, err := execRequest(sqliteRequest(path, "INSERT INTO b VALUES (42)")); err == nil {
		t.Fatal("insert violating a foreign key succeeded, want an error")
	}
}

func TestSQLiteRowCap(t *testing.T) {
	path := newSQLiteFile(t)
	req := sqliteRequest(path, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10) SELECT i FROM n")
	req.MaxRows = 3
	resp, err := execRequest(req)
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Truncated || resp.RowCount != 3 {
		t.Errorf("row_count = %d truncated = %v, want 3 and true", resp.RowCount, resp.Truncated)
	}
}

func TestSQLiteMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.db")
	_, err := execRequest(sqliteRequest(path, "SELECT 1"))
	if err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("error = %v, want a missing-file error", err)
	}
	if _, statErr := os.Stat(path); statErr == nil {
		t.Error("the missing database file was created")
	}
}

func TestSQLiteRejectsProxy(t *testing.T) {
	req := sqliteRequest(newSQLiteFile(t), "SELECT 1")
	req.Proxy = &ProxyConfig{Type: "socks5", Host: "localhost", Port: 1080}
	if _, err := execRequest(req); err == nil {
		t.Fatal("sqlite request with a proxy succeeded, want an error")
	}
}

func TestSQLiteDSNOptions(t *testing.T) {
	req := &Request{Database: "/data/app.db", Options: map[string]string{"_txlock": "immediate"}}
	dsn := sqliteDSN(req)
	for _, part := range []string{"/data/app.db?", "_pragma=foreign_keys%281%29", "_pragma=busy_timeout%285000%29", "_txlock=immediate"} {
		if !strings.Contains(dsn, part) {
			t.Errorf("sqliteDSN() = %q, missing %q", dsn, part)
		}
	}
}
