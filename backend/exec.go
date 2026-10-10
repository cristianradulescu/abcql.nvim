package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// writeQueryRe matches the first keyword of a query to classify INSERT/UPDATE/DELETE
// as "write" queries (Exec), mirroring the heuristic MySQLAdapter:is_write_query used
// on the Lua side before this logic moved here.
var writeQueryRe = regexp.MustCompile(`(?i)^\s*(INSERT|UPDATE|DELETE|REPLACE)\b`)

func isWriteQuery(sql string) bool {
	return writeQueryRe.MatchString(sql)
}

// execRequest dispatches the request to the engine it names; an empty engine
// means MySQL, for requests written before other engines existed.
func execRequest(req *Request) (*Response, error) {
	switch req.Engine {
	case "", "mysql":
		return execMySQL(req)
	case "sqlite":
		return execSQLite(req)
	default:
		return nil, fmt.Errorf("unsupported engine %q", req.Engine)
	}
}

// execer is the part of *sql.DB and *sql.Conn the statement runners need, so
// the same code runs a lone statement on the pool and a batch on one pinned
// connection.
type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func requestTimeout(req *Request) time.Duration {
	if req.TimeoutMs > 0 {
		return time.Duration(req.TimeoutMs) * time.Millisecond
	}
	return 30 * time.Second
}

// runSQL runs the request on an already opened db: a single statement on the
// pool, or, when the request carries statements, a batch on one connection.
func runSQL(db *sql.DB, req *Request, kindFor func(*sql.ColumnType) columnKind) (*Response, error) {
	if len(req.Statements) > 0 {
		return runBatch(db, req, kindFor)
	}
	return runStatement(db, req.SQL, int(req.MaxRows), requestTimeout(req), kindFor)
}

// runStatement runs one statement with its own timeout and row cap, and times
// the round trip.
func runStatement(conn execer, query string, maxRows int, timeout time.Duration, kindFor func(*sql.ColumnType) columnKind) (*Response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return runStatementCtx(ctx, conn, query, maxRows, kindFor)
}

// runStatementCtx runs one statement under ctx and times the round trip. A
// persistent session passes a context without a deadline (see session.go).
func runStatementCtx(ctx context.Context, conn execer, query string, maxRows int, kindFor func(*sql.ColumnType) columnKind) (*Response, error) {
	start := time.Now()

	var resp *Response
	var err error
	if isWriteQuery(query) {
		resp, err = execWrite(ctx, conn, query)
	} else {
		resp, err = execQuery(ctx, conn, query, maxRows, kindFor)
	}
	if err != nil {
		return nil, err
	}

	resp.DurationMs = float64(time.Since(start)) / float64(time.Millisecond)
	return resp, nil
}

// runStatements runs the statements in order through run, stopping at the
// first error. Nothing is ever committed on the user's behalf: when the
// connection closes the server rolls back whatever transaction a script left
// open.
//
// A failing statement is reported inside the Response (its error, index and
// the results before it), not as an error, so the caller still gets the
// results of the statements that did run.
func runStatements(stmts []Statement, run func(Statement) (*Response, error)) *Response {
	start := time.Now()
	resp := &Response{Results: make([]*Response, 0, len(stmts))}
	for i, stmt := range stmts {
		result, err := run(stmt)
		if err != nil {
			resp.Error = err.Error()
			resp.FailedIndex = &i
			break
		}
		resp.Results = append(resp.Results, result)
	}

	resp.DurationMs = float64(time.Since(start)) / float64(time.Millisecond)
	return resp
}

// runBatch runs the request's statements in order on a single connection
// (not the pool), each with its own timeout, stopping at the first error.
func runBatch(db *sql.DB, req *Request, kindFor func(*sql.ColumnType) columnKind) (*Response, error) {
	timeout := requestTimeout(req)

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	conn, err := db.Conn(ctx)
	cancel()
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	return runStatements(req.Statements, func(stmt Statement) (*Response, error) {
		return runStatement(conn, stmt.SQL, int(stmt.MaxRows), timeout, kindFor)
	}), nil
}

func execWrite(ctx context.Context, db execer, query string) (*Response, error) {
	result, err := db.ExecContext(ctx, query)
	if err != nil {
		return nil, err
	}

	affected, err := result.RowsAffected()
	if err != nil {
		// Some statements (e.g. DDL) don't support RowsAffected; treat as 0
		// rather than failing the whole request.
		affected = 0
	}

	return &Response{
		QueryType:    "write",
		Headers:      []string{},
		Rows:         [][]string{},
		RowCount:     0,
		AffectedRows: affected,
		// MatchedRows/ChangedRows: database/sql doesn't expose the distinct
		// "matched vs changed" figures MySQL's mysql_info() reports (that
		// requires the CLIENT_FOUND_ROWS capability and free-text parsing
		// the driver doesn't surface). Best-effort: mirror affected_rows.
		MatchedRows: affected,
		ChangedRows: affected,
		Warnings:    0,
	}, nil
}

// columnKind tells formatValue how to render a column's values: raw []byte
// values (which the MySQL driver returns for text and binary columns alike)
// and dates, which drivers scan into a time.Time with a zero time of day.
type columnKind int

const (
	kindText columnKind = iota
	kindBinary
	kindBit
	kindDate
)

func columnKinds(rows *sql.Rows, columnCount int, kindFor func(*sql.ColumnType) columnKind) []columnKind {
	kinds := make([]columnKind, columnCount)
	types, err := rows.ColumnTypes()
	if err != nil {
		// Types are only a formatting hint; formatValue still hex-encodes
		// bytes that aren't valid UTF-8.
		return kinds
	}
	for i, ct := range types {
		kinds[i] = kindFor(ct)
	}
	return kinds
}

// rowScanner is the subset of *sql.Rows collectRows needs, so the row-cap
// logic can be unit tested without a database.
type rowScanner interface {
	Next() bool
	Scan(dest ...interface{}) error
	Err() error
}

// collectRows drains rows into string cells, stopping after maxRows rows
// (when maxRows > 0). The second return value reports whether more rows were
// available beyond the cap. kinds holds one entry per column.
func collectRows(rows rowScanner, kinds []columnKind, maxRows int) ([][]string, bool, error) {
	columnCount := len(kinds)
	result := make([][]string, 0)
	values := make([]interface{}, columnCount)
	scanDest := make([]interface{}, columnCount)
	for i := range values {
		scanDest[i] = &values[i]
	}

	truncated := false
	for rows.Next() {
		if maxRows > 0 && len(result) >= maxRows {
			truncated = true
			break
		}
		if err := rows.Scan(scanDest...); err != nil {
			return nil, false, err
		}
		row := make([]string, columnCount)
		for i, v := range values {
			row[i] = formatValue(v, kinds[i])
		}
		result = append(result, row)
	}
	if !truncated {
		if err := rows.Err(); err != nil {
			return nil, false, err
		}
	}

	return result, truncated, nil
}

func execQuery(ctx context.Context, db execer, query string, maxRows int, kindFor func(*sql.ColumnType) columnKind) (*Response, error) {
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}

	result, truncated, err := collectRows(rows, columnKinds(rows, len(columns), kindFor), maxRows)
	if err != nil {
		return nil, err
	}

	return &Response{
		QueryType: "select",
		Headers:   columns,
		Rows:      result,
		RowCount:  len(result),
		Truncated: truncated,
	}, nil
}

// formatValue converts a scanned column value to its canonical text form,
// matching what the mysql CLI would have printed (including the literal
// string "NULL" for SQL NULL, since the rest of the plugin already renders
// and highlights based on that convention). Binary values are rendered as a
// 0x-prefixed hex literal (valid MySQL syntax, so a copied cell can be pasted
// back into a query) instead of raw bytes, which would otherwise be mangled
// into U+FFFD by JSON encoding and break the results table layout; BIT
// values are rendered as their unsigned integer value.
func formatValue(v interface{}, kind columnKind) string {
	if v == nil {
		return "NULL"
	}

	switch val := v.(type) {
	case []byte:
		switch {
		case kind == kindBit && len(val) <= 8:
			var n uint64
			for _, b := range val {
				n = n<<8 | uint64(b)
			}
			return strconv.FormatUint(n, 10)
		case kind == kindBinary || !utf8.Valid(val):
			return formatHex(val)
		}
		return string(val)
	case time.Time:
		if kind == kindDate {
			return val.Format("2006-01-02")
		}
		return val.Format("2006-01-02 15:04:05")
	case string:
		return val
	default:
		return fmt.Sprintf("%v", val)
	}
}

func formatHex(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	return "0x" + strings.ToUpper(hex.EncodeToString(b))
}
