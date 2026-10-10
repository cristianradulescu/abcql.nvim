package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeSession is a sessionDB on a pinned SQLite connection, with a scripted
// transaction state, so the serve loop is tested without MySQL.
type fakeSession struct {
	conn *sql.Conn

	mu       sync.Mutex
	state    SessionState
	stateErr error
	execErr  error         // returned by every statement
	block    chan struct{} // when set, statements wait for it to close
	closed   atomic.Bool
	kills    atomic.Int32
}

func newFakeSession(t *testing.T) *fakeSession {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return &fakeSession{conn: conn, state: SessionState{ConnectionID: 7, Database: "main", Autocommit: true}}
}

func (f *fakeSession) wait(ctx context.Context) error {
	f.mu.Lock()
	block, err := f.block, f.execErr
	f.mu.Unlock()
	if block != nil {
		select {
		case <-block:
			return errors.New("Error 1317: Query execution was interrupted")
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}

func (f *fakeSession) ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error) {
	if err := f.wait(ctx); err != nil {
		return nil, err
	}
	return f.conn.ExecContext(ctx, q, args...)
}

func (f *fakeSession) QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error) {
	if err := f.wait(ctx); err != nil {
		return nil, err
	}
	return f.conn.QueryContext(ctx, q, args...)
}

func (f *fakeSession) State(context.Context) (*SessionState, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.stateErr != nil {
		return nil, f.stateErr
	}
	state := f.state
	return &state, nil
}

func (f *fakeSession) Interrupt() error {
	f.kills.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.block != nil {
		close(f.block)
		f.block = nil
	}
	return nil
}

func (f *fakeSession) Close() error {
	f.closed.Store(true)
	return nil
}

// harness runs runServe on pipes.
type harness struct {
	t     *testing.T
	in    *io.PipeWriter
	out   *bufio.Reader
	fake  *fakeSession
	exit  chan int
	state *SessionState
}

func startServe(t *testing.T, fake *fakeSession) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &harness{t: t, in: inW, out: bufio.NewReader(outR), fake: fake, exit: make(chan int, 1)}
	go func() {
		h.exit <- runServe(inR, outW, func(*Request) (sessionDB, *SessionState, error) {
			state := fake.state
			return fake, &state, nil
		})
		outW.Close()
	}()
	t.Cleanup(func() { inW.Close() })
	h.send(`{"engine":"mysql"}`)
	if first := h.read(); first.Session == nil || first.Session.ConnectionID != 7 {
		t.Fatalf("open reply = %+v, want the session state", first)
	}
	return h
}

func (h *harness) send(line string) {
	h.t.Helper()
	if _, err := io.WriteString(h.in, line+"\n"); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) read() *Response {
	h.t.Helper()
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		line, err := h.out.ReadString('\n')
		ch <- result{line, err}
	}()
	select {
	case r := <-ch:
		if r.err != nil {
			h.t.Fatalf("reading reply: %v", r.err)
		}
		var resp Response
		if err := json.Unmarshal([]byte(r.line), &resp); err != nil {
			h.t.Fatalf("reply %q is not one JSON object: %v", r.line, err)
		}
		return &resp
	case <-time.After(5 * time.Second):
		h.t.Fatal("timed out waiting for a reply")
		return nil
	}
}

func (h *harness) waitExit() int {
	h.t.Helper()
	select {
	case code := <-h.exit:
		return code
	case <-time.After(5 * time.Second):
		h.t.Fatal("serve did not exit")
		return -1
	}
}

func execLine(id int, timeoutMs int, sqls ...string) string {
	stmts := make([]string, len(sqls))
	for i, q := range sqls {
		stmts[i] = fmt.Sprintf(`{"sql":%q}`, q)
	}
	return fmt.Sprintf(`{"id":%d,"op":"exec","timeout_ms":%d,"statements":[%s]}`, id, timeoutMs, strings.Join(stmts, ","))
}

func TestServeExecReplyCarriesIDAndState(t *testing.T) {
	h := startServe(t, newFakeSession(t))
	h.fake.state.InTransaction = true
	h.fake.state.RowsModified = 3
	h.send(execLine(5, 0, "CREATE TABLE t (a INTEGER)", "SELECT 1"))
	resp := h.read()
	if resp.ID != 5 || resp.Error != "" || len(resp.Results) != 2 {
		t.Fatalf("resp = %+v, want id 5 and two results", resp)
	}
	if resp.Session == nil || !resp.Session.InTransaction || resp.Session.RowsModified != 3 {
		t.Errorf("session = %+v, want the transaction state", resp.Session)
	}
}

func TestServeStatementsShareTheConnectionAcrossRuns(t *testing.T) {
	h := startServe(t, newFakeSession(t))
	h.send(execLine(1, 0, "CREATE TEMP TABLE t (a INTEGER)", "INSERT INTO t VALUES (1)"))
	h.read()
	h.send(execLine(2, 0, "SELECT a FROM t"))
	resp := h.read()
	if resp.Error != "" || resp.Results[0].Rows[0][0] != "1" {
		t.Fatalf("resp = %+v, want the row written by the earlier run", resp)
	}
}

func TestServeErrorInTransactionSaysItIsStillOpen(t *testing.T) {
	h := startServe(t, newFakeSession(t))
	h.fake.state.InTransaction = true
	h.send(execLine(1, 0, "SELECT * FROM missing"))
	resp := h.read()
	if resp.FailedIndex == nil || !strings.Contains(resp.Error, "transaction is still open") {
		t.Errorf("resp = %+v, want a failed statement and the open transaction mentioned", resp)
	}
	if resp.SessionLost {
		t.Error("a failing statement must not lose the session")
	}
}

func TestServeRejectsExecWhileBusyAndCancelKeepsSession(t *testing.T) {
	fake := newFakeSession(t)
	fake.block = make(chan struct{})
	h := startServe(t, fake)

	h.send(execLine(1, 0, "SELECT 1"))
	h.send(execLine(2, 0, "SELECT 2"))
	if busy := h.read(); busy.ID != 2 || !strings.Contains(busy.Error, "busy") {
		t.Fatalf("second exec reply = %+v, want a busy error for id 2", busy)
	}

	h.send(`{"id":3,"op":"cancel"}`)
	ack, failed := h.read(), h.read()
	if ack.ID != 3 || ack.Error != "" {
		t.Errorf("cancel reply = %+v, want a plain ack", ack)
	}
	if failed.ID != 1 || !strings.Contains(failed.Error, "cancelled") || failed.SessionLost {
		t.Errorf("exec reply = %+v, want a cancelled error that keeps the session", failed)
	}
	if fake.kills.Load() != 1 {
		t.Errorf("interrupts = %d, want 1", fake.kills.Load())
	}

	// The session still works.
	h.send(execLine(4, 0, "SELECT 3"))
	if resp := h.read(); resp.ID != 4 || resp.Error != "" {
		t.Errorf("run after cancel = %+v, want success", resp)
	}
}

func TestServeTimeoutInterruptsInsteadOfKillingTheConnection(t *testing.T) {
	fake := newFakeSession(t)
	fake.block = make(chan struct{})
	h := startServe(t, fake)

	h.send(execLine(1, 50, "SELECT 1"))
	resp := h.read()
	if !strings.Contains(resp.Error, "timed out") || resp.SessionLost || resp.Session == nil {
		t.Errorf("resp = %+v, want a timeout error with the session kept", resp)
	}
	if fake.kills.Load() != 1 {
		t.Errorf("interrupts = %d, want 1", fake.kills.Load())
	}
}

func TestServeLostConnectionRepliesThenExits(t *testing.T) {
	fake := newFakeSession(t)
	fake.execErr = fmt.Errorf("write: %w", sql.ErrConnDone)
	h := startServe(t, fake)

	h.send(execLine(1, 0, "SELECT 1", "SELECT 2"))
	resp := h.read()
	if !resp.SessionLost || !strings.Contains(resp.Error, "rolls back") || resp.Session != nil {
		t.Fatalf("resp = %+v, want session_lost and the rollback explanation", resp)
	}
	if code := h.waitExit(); code != 1 {
		t.Errorf("exit code = %d, want 1", code)
	}
	if !fake.closed.Load() {
		t.Error("connection was not closed")
	}
}

func TestServeUnreadableStateLosesTheSession(t *testing.T) {
	fake := newFakeSession(t)
	h := startServe(t, fake)
	fake.stateErr = errors.New("Error 1227: Access denied")

	h.send(execLine(1, 0, "SELECT 1"))
	if resp := h.read(); !resp.SessionLost {
		t.Fatalf("resp = %+v, want session_lost", resp)
	}
	if h.waitExit() != 1 || !fake.closed.Load() {
		t.Error("want exit 1 with the connection closed")
	}
}

func TestServeStdinEOFClosesTheConnection(t *testing.T) {
	fake := newFakeSession(t)
	h := startServe(t, fake)
	h.in.Close()
	if code := h.waitExit(); code != 0 || !fake.closed.Load() {
		t.Errorf("exit = %d, closed = %v, want 0 and closed", code, fake.closed.Load())
	}
}

func TestServeStdinEOFDuringExecDropsTheStatement(t *testing.T) {
	fake := newFakeSession(t)
	fake.block = make(chan struct{})
	h := startServe(t, fake)

	h.send(execLine(1, 0, "SELECT 1"))
	time.Sleep(50 * time.Millisecond)
	h.in.Close()
	h.waitExit()
	if !fake.closed.Load() {
		t.Error("connection was not closed")
	}
}

func TestServeTruncatedLastLineIsNotRun(t *testing.T) {
	fake := newFakeSession(t)
	h := startServe(t, fake)
	io.WriteString(h.in, `{"id":1,"op":"close"}`) // no newline: the pipe broke mid-write
	h.in.Close()
	if code := h.waitExit(); code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}
}

func TestServeCloseAndBadInput(t *testing.T) {
	h := startServe(t, newFakeSession(t))
	h.send("not json")
	if resp := h.read(); resp.Error == "" {
		t.Error("want an error for a malformed line")
	}
	h.send(`{"id":2,"op":"frobnicate"}`)
	if resp := h.read(); resp.ID != 2 || resp.Error == "" {
		t.Errorf("resp = %+v, want an unknown-op error for id 2", resp)
	}
	h.send(`{"id":3,"op":"cancel"}`)
	if resp := h.read(); resp.ID != 3 || resp.Error != "" {
		t.Errorf("idle cancel = %+v, want a plain ack", resp)
	}
	h.send(`{"id":4,"op":"close"}`)
	if resp := h.read(); resp.ID != 4 {
		t.Errorf("close reply = %+v", resp)
	}
	if h.waitExit() != 0 || !h.fake.closed.Load() {
		t.Error("want exit 0 with the connection closed")
	}
}

func TestRunServeRefusals(t *testing.T) {
	for name, tc := range map[string]struct{ in, want string }{
		"sqlite":      {`{"engine":"sqlite","database":"x.db"}` + "\n", "MySQL-only"},
		"not json":    {"nope\n", "parse"},
		"no request":  {"", "read"},
		"open failed": {`{"engine":"mysql"}` + "\n", "PROCESS"},
	} {
		t.Run(name, func(t *testing.T) {
			var out strings.Builder
			open := openSession
			if name == "open failed" {
				open = func(*Request) (sessionDB, *SessionState, error) {
					return nil, nil, errors.New("persistent session needs the PROCESS privilege to track transactions")
				}
			}
			if code := runServe(strings.NewReader(tc.in), &out, open); code != 1 {
				t.Errorf("exit = %d, want 1", code)
			}
			var resp Response
			if err := json.Unmarshal([]byte(out.String()), &resp); err != nil || !strings.Contains(resp.Error, tc.want) || resp.Session != nil {
				t.Errorf("reply = %q, want an error containing %q", out.String(), tc.want)
			}
		})
	}
}

func TestIsConnLost(t *testing.T) {
	if !isConnLost(fmt.Errorf("x: %w", io.ErrUnexpectedEOF)) || !isConnLost(sql.ErrConnDone) {
		t.Error("EOF and ErrConnDone mean the connection is lost")
	}
	if isConnLost(errors.New("Error 1064: syntax error")) {
		t.Error("a failing statement does not lose the connection")
	}
}

// Live MySQL: ABCQL_TEST_MYSQL=user:password@127.0.0.1:33060/employees (the
// user needs PROCESS). Checks what a fake can't: that the probe reflects the
// server's transaction state and never opens a transaction itself.
func TestMySQLSessionTransactionState(t *testing.T) {
	dsn := os.Getenv("ABCQL_TEST_MYSQL")
	if dsn == "" {
		t.Skip("ABCQL_TEST_MYSQL not set")
	}
	var user, pass, host, db string
	var port int
	if _, err := fmt.Sscanf(strings.NewReplacer(":", " ", "@", " ", "/", " ").Replace(dsn), "%s %s %s %d %s", &user, &pass, &host, &port, &db); err != nil {
		t.Fatal(err)
	}
	m, state, err := openMySQLSession(&Request{User: user, Password: pass, Host: host, Port: flexInt(port), Database: db})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if state.InTransaction || state.Database != db {
		t.Fatalf("fresh state = %+v", state)
	}

	ctx := context.Background()
	for _, q := range []string{"SET autocommit = 0", "CREATE TEMPORARY TABLE abcql_probe (a INT) ENGINE=InnoDB"} {
		if _, err := m.ExecContext(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		if state, err = m.State(ctx); err != nil || state.Autocommit || state.InTransaction {
			t.Fatalf("probe %d with autocommit=0 = %+v, %v; the probe must not open a transaction", i, state, err)
		}
	}
	if _, err := m.ExecContext(ctx, "INSERT INTO abcql_probe VALUES (1), (2)"); err != nil {
		t.Fatal(err)
	}
	if state, _ = m.State(ctx); !state.InTransaction || state.RowsModified != 2 {
		t.Errorf("after INSERT = %+v, want an open transaction with 2 rows", state)
	}
	if _, err := m.ExecContext(ctx, "ROLLBACK"); err != nil {
		t.Fatal(err)
	}
	if state, _ = m.State(ctx); state.InTransaction {
		t.Errorf("after ROLLBACK = %+v, want no transaction", state)
	}
}
