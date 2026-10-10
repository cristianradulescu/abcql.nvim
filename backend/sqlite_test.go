package main

import (
	"bytes"
	"encoding/json"
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

func sqliteBatch(path string, statements ...Statement) *Request {
	return &Request{Engine: "sqlite", Database: path, Statements: statements}
}

func TestSQLiteBatchSharesConnection(t *testing.T) {
	path := newSQLiteFile(t)
	resp, err := execRequest(sqliteBatch(path,
		Statement{SQL: "CREATE TEMPORARY TABLE tmp (n INTEGER)"},
		Statement{SQL: "INSERT INTO tmp VALUES (7)"},
		Statement{SQL: "SELECT n FROM tmp"},
	))
	if err != nil {
		t.Fatal(err)
	}
	if resp.Error != "" || resp.FailedIndex != nil || len(resp.Results) != 3 {
		t.Fatalf("resp = %+v, want 3 results and no error", resp)
	}
	if got := resp.Results[2]; got.QueryType != "select" || got.Rows[0][0] != "7" {
		t.Errorf("last result = %+v, want the temp table row", got)
	}
}

func TestSQLiteBatchRollback(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE t (id INTEGER)")
	_, err := execRequest(sqliteBatch(path,
		Statement{SQL: "BEGIN"},
		Statement{SQL: "INSERT INTO t VALUES (1)"},
		Statement{SQL: "ROLLBACK"},
	))
	if err != nil {
		t.Fatal(err)
	}
	if resp := mustExec(t, path, "SELECT * FROM t"); resp.RowCount != 0 {
		t.Errorf("row_count = %d, want 0 after ROLLBACK", resp.RowCount)
	}
}

func TestSQLiteBatchOpenTransactionIsNotCommitted(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE t (id INTEGER)")
	_, err := execRequest(sqliteBatch(path,
		Statement{SQL: "BEGIN"},
		Statement{SQL: "INSERT INTO t VALUES (1)"},
	))
	if err != nil {
		t.Fatal(err)
	}
	if resp := mustExec(t, path, "SELECT * FROM t"); resp.RowCount != 0 {
		t.Errorf("row_count = %d, want 0: an unfinished transaction must not be committed", resp.RowCount)
	}
}

func TestSQLiteBatchStopsAtFirstError(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE t (id INTEGER)")
	resp, err := execRequest(sqliteBatch(path,
		Statement{SQL: "INSERT INTO t VALUES (1)"},
		Statement{SQL: "SELECT * FROM missing"},
		Statement{SQL: "INSERT INTO t VALUES (2)"},
	))
	if err != nil {
		t.Fatal(err)
	}
	if resp.FailedIndex == nil || *resp.FailedIndex != 1 || resp.Error == "" {
		t.Fatalf("resp = %+v, want failed_index 1 and an error", resp)
	}
	if len(resp.Results) != 1 || resp.Results[0].AffectedRows != 1 {
		t.Errorf("results = %+v, want only the first insert", resp.Results)
	}
	if got := mustExec(t, path, "SELECT * FROM t"); got.RowCount != 1 {
		t.Errorf("row_count = %d, want 1: the statement after the failure must not run", got.RowCount)
	}
}

func TestSQLiteBatchRowCapPerStatement(t *testing.T) {
	path := newSQLiteFile(t)
	numbers := "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10) SELECT i FROM n"
	resp, err := execRequest(sqliteBatch(path,
		Statement{SQL: numbers, MaxRows: 3},
		Statement{SQL: numbers},
	))
	if err != nil {
		t.Fatal(err)
	}
	if first := resp.Results[0]; first.RowCount != 3 || !first.Truncated {
		t.Errorf("first = %d rows truncated %v, want 3 and true", first.RowCount, first.Truncated)
	}
	if second := resp.Results[1]; second.RowCount != 10 || second.Truncated {
		t.Errorf("second = %d rows truncated %v, want 10 and false", second.RowCount, second.Truncated)
	}
}

func TestSingleStatementResponseHasNoBatchFields(t *testing.T) {
	var out bytes.Buffer
	path := newSQLiteFile(t)
	body, _ := json.Marshal(map[string]any{"engine": "sqlite", "database": path, "sql": "SELECT 1"})
	if code := runExec(bytes.NewReader(body), &out); code != 0 {
		t.Fatalf("exit code = %d, output %s", code, out.String())
	}
	if s := out.String(); strings.Contains(s, "results") || strings.Contains(s, "failed_index") {
		t.Errorf("single-statement response %s has batch fields", s)
	}
}

func TestRunExecPartialBatchFailureIsValidJSON(t *testing.T) {
	var out bytes.Buffer
	path := newSQLiteFile(t)
	body, _ := json.Marshal(map[string]any{
		"engine": "sqlite", "database": path,
		"statements": []map[string]any{{"sql": "SELECT 1"}, {"sql": "SELECT * FROM missing"}},
	})
	if code := runExec(bytes.NewReader(body), &out); code != 1 {
		t.Errorf("exit code = %d, want 1", code)
	}
	var resp Response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("output %q is not valid JSON: %v", out.String(), err)
	}
	if len(resp.Results) != 1 || resp.FailedIndex == nil || *resp.FailedIndex != 1 {
		t.Errorf("resp = %+v", resp)
	}
}

func TestSQLiteBatchTimeoutStopsTheBatch(t *testing.T) {
	path := newSQLiteFile(t)
	mustExec(t, path, "CREATE TABLE t (id INTEGER)")
	forever := "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"
	req := sqliteBatch(path,
		Statement{SQL: "BEGIN"},
		Statement{SQL: "INSERT INTO t VALUES (1)"},
		Statement{SQL: forever},
		Statement{SQL: "INSERT INTO t VALUES (2)"},
	)
	req.TimeoutMs = 50
	resp, err := execRequest(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.FailedIndex == nil || *resp.FailedIndex != 2 || resp.Error == "" {
		t.Fatalf("resp = %+v, want failed_index 2 and an error", resp)
	}
	if len(resp.Results) != 2 {
		t.Errorf("results = %d, want the 2 statements before the timeout", len(resp.Results))
	}
	if got := mustExec(t, path, "SELECT * FROM t"); got.RowCount != 0 {
		t.Errorf("row_count = %d, want 0: later statements must not run and the open transaction must not be committed", got.RowCount)
	}
}
