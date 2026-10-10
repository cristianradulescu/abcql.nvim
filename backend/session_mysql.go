package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/go-sql-driver/mysql"
)

// stateSQL reads the connection's transaction state. The LEFT JOIN keeps the
// row when the connection has no transaction. Reading innodb_trx needs the
// PROCESS privilege, and it does not itself open a transaction (it touches
// no InnoDB table), so the probe is safe with autocommit=0.
const stateSQL = `SELECT @@autocommit, DATABASE(), t.trx_rows_modified, t.trx_rows_locked
FROM (SELECT 1) AS d
LEFT JOIN information_schema.innodb_trx AS t ON t.trx_mysql_thread_id = CONNECTION_ID()`

// mysqlSession is one pinned *sql.Conn to MySQL.
type mysqlSession struct {
	db   *sql.DB
	conn *sql.Conn
	id   int64
	dsn  string // for the short-lived connection that sends KILL QUERY

	lastProbe time.Time
}

// trxCacheTTL: the server reuses its innodb_trx snapshot when it is read
// again within 100 ms, which would hide a transaction opened since the last
// probe (a first run right after the session opened, say). State waits out
// the window so the answer reflects the statements that just ran.
const trxCacheTTL = 120 * time.Millisecond

func (m *mysqlSession) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	return m.conn.ExecContext(ctx, query, args...)
}

func (m *mysqlSession) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	return m.conn.QueryContext(ctx, query, args...)
}

func (m *mysqlSession) State(ctx context.Context) (*SessionState, error) {
	time.Sleep(trxCacheTTL - time.Since(m.lastProbe))
	defer func() { m.lastProbe = time.Now() }()

	var autocommit int
	var database sql.NullString
	var modified, locked sql.NullInt64
	if err := m.conn.QueryRowContext(ctx, stateSQL).Scan(&autocommit, &database, &modified, &locked); err != nil {
		return nil, err
	}
	return &SessionState{
		ConnectionID:  m.id,
		Database:      database.String,
		Autocommit:    autocommit == 1,
		InTransaction: modified.Valid,
		RowsModified:  modified.Int64,
		RowsLocked:    locked.Int64,
	}, nil
}

// Interrupt kills the running statement from a side connection. Under InnoDB
// only that statement is rolled back; an open transaction stays open.
func (m *mysqlSession) Interrupt() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	db, err := sql.Open("mysql", m.dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	_, err = db.ExecContext(ctx, fmt.Sprintf("KILL QUERY %d", m.id))
	return err
}

// Close ends the connection; the server rolls back an open transaction.
func (m *mysqlSession) Close() error {
	m.conn.Close()
	return m.db.Close()
}

// openMySQLSession connects, pins a connection and probes the transaction
// state. Without the PROCESS privilege the state can't be tracked, so the
// session is refused rather than run blind.
func openMySQLSession(req *Request) (sessionDB, *SessionState, error) {
	network := registerDirectDialer()
	if req.Proxy != nil {
		var err error
		if network, err = registerProxyDialer(req.Proxy); err != nil {
			return nil, nil, err
		}
	}
	dsn := buildDSN(req, network)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to open connection: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout(req))
	defer cancel()
	m := &mysqlSession{db: db, dsn: dsn}
	fail := func(err error) (sessionDB, *SessionState, error) {
		m.Close()
		return nil, nil, err
	}
	if m.conn, err = db.Conn(ctx); err != nil {
		db.Close()
		return nil, nil, err
	}
	if err := m.conn.QueryRowContext(ctx, "SELECT CONNECTION_ID()").Scan(&m.id); err != nil {
		return fail(err)
	}
	state, err := m.State(ctx)
	if err != nil {
		var myErr *mysql.MySQLError
		if errors.As(err, &myErr) && myErr.Number == 1227 {
			return fail(errors.New("persistent session needs the PROCESS privilege to track transactions"))
		}
		return fail(fmt.Errorf("persistent session could not read the transaction state: %w", err))
	}
	return m, state, nil
}
