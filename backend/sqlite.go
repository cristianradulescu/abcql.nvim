package main

import (
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"strings"

	_ "modernc.org/sqlite"
)

// sqliteDSN builds a modernc.org/sqlite DSN from the database file path.
// Foreign keys are enforced (SQLite leaves them off per connection by
// default) and a busy timeout avoids failing immediately when another
// process holds a write lock; request options are passed through verbatim,
// e.g. {"_pragma": "journal_mode(WAL)"}.
func sqliteDSN(req *Request) string {
	params := url.Values{}
	params.Add("_pragma", "foreign_keys(1)")
	params.Add("_pragma", "busy_timeout(5000)")
	for k, v := range req.Options {
		params.Add(k, v)
	}
	return req.Database + "?" + params.Encode()
}

// execSQLite opens the SQLite file named by req.Database, runs the request's
// SQL, and returns a fully populated Response.
func execSQLite(req *Request) (*Response, error) {
	if req.Database == "" {
		return nil, errors.New("sqlite: no database file given")
	}
	if req.Proxy != nil {
		return nil, errors.New("sqlite: a proxy can't be used with a local database file")
	}
	// SQLite silently creates a missing file, which turns a typo in the path
	// into an empty database; require it to exist (":memory:" aside).
	if req.Database != ":memory:" && !strings.HasPrefix(req.Database, "file:") {
		if _, err := os.Stat(req.Database); errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("sqlite: database file %s does not exist", req.Database)
		}
	}

	db, err := sql.Open("sqlite", sqliteDSN(req))
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}
	defer db.Close()

	return runSQL(db, req, sqliteColumnKind)
}

// sqliteColumnKind: the driver returns TEXT values as strings and only BLOB
// values as []byte, so any []byte is binary regardless of the declared type.
// DATE-declared columns come back as time.Time and are shown without a time.
func sqliteColumnKind(ct *sql.ColumnType) columnKind {
	if ct.DatabaseTypeName() == "DATE" {
		return kindDate
	}
	return kindBinary
}
