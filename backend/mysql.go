package main

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// writeQueryRe matches the first keyword of a query to classify INSERT/UPDATE/DELETE
// as "write" queries (Exec), mirroring the heuristic MySQLAdapter:is_write_query used
// on the Lua side before this logic moved here.
var writeQueryRe = regexp.MustCompile(`(?i)^\s*(INSERT|UPDATE|DELETE)\b`)

func isWriteQuery(sql string) bool {
	return writeQueryRe.MatchString(sql)
}

// buildDSN converts a Request's structured connection fields into a
// go-sql-driver/mysql DSN string. Returns the network name to plug into the
// DSN too, since a SOCKS proxy (if configured) is wired in via a custom
// registered network rather than DSN host/port rewriting.
func buildDSN(req *Request, network string) string {
	var b strings.Builder

	if req.User != "" {
		b.WriteString(req.User)
		if req.Password != "" {
			b.WriteString(":")
			b.WriteString(req.Password)
		}
		b.WriteString("@")
	}

	host := req.Host
	if host == "" {
		host = "localhost"
	}
	port := int(req.Port)
	if port == 0 {
		port = 3306
	}

	b.WriteString(network)
	b.WriteString("(")
	b.WriteString(host)
	b.WriteString(":")
	b.WriteString(strconv.Itoa(port))
	b.WriteString(")/")
	b.WriteString(req.Database)

	params := []string{"parseTime=true"}
	for k, v := range req.Options {
		params = append(params, fmt.Sprintf("%s=%s", k, v))
	}
	b.WriteString("?")
	b.WriteString(strings.Join(params, "&"))

	return b.String()
}

// execRequest connects to MySQL, runs the request's SQL, and returns a fully
// populated Response.
func execRequest(req *Request) (*Response, error) {
	network := "tcp"
	if req.Proxy != nil {
		var err error
		network, err = registerProxyDialer(req.Proxy)
		if err != nil {
			return nil, err
		}
	}

	dsn := buildDSN(req, network)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open connection: %w", err)
	}
	defer db.Close()

	timeout := 30 * time.Second
	if req.TimeoutMs > 0 {
		timeout = time.Duration(req.TimeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	start := time.Now()

	var resp *Response
	if isWriteQuery(req.SQL) {
		resp, err = execWrite(ctx, db, req.SQL)
	} else {
		resp, err = execQuery(ctx, db, req.SQL)
	}
	if err != nil {
		return nil, err
	}

	resp.DurationMs = float64(time.Since(start)) / float64(time.Millisecond)
	return resp, nil
}

func execWrite(ctx context.Context, db *sql.DB, query string) (*Response, error) {
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

func execQuery(ctx context.Context, db *sql.DB, query string) (*Response, error) {
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}

	result := make([][]string, 0)
	values := make([]interface{}, len(columns))
	scanDest := make([]interface{}, len(columns))
	for i := range values {
		scanDest[i] = &values[i]
	}

	for rows.Next() {
		if err := rows.Scan(scanDest...); err != nil {
			return nil, err
		}
		row := make([]string, len(columns))
		for i, v := range values {
			row[i] = formatValue(v)
		}
		result = append(result, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return &Response{
		QueryType: "select",
		Headers:   columns,
		Rows:      result,
		RowCount:  len(result),
	}, nil
}

// formatValue converts a scanned column value to its canonical text form,
// matching what the mysql CLI would have printed (including the literal
// string "NULL" for SQL NULL, since the rest of the plugin already renders
// and highlights based on that convention).
func formatValue(v interface{}) string {
	if v == nil {
		return "NULL"
	}

	switch val := v.(type) {
	case []byte:
		return string(val)
	case time.Time:
		return val.Format("2006-01-02 15:04:05")
	case string:
		return val
	default:
		return fmt.Sprintf("%v", val)
	}
}
