package main

// A persistent session ("abcql-backend serve") keeps one database connection
// open across runs, so a transaction, SET @var, USE or temporary table
// survives from one run to the next. One process serves exactly one session
// (one Neovim buffer) and never reconnects: if the connection breaks the
// session is reported lost and the process exits, so a statement can never
// silently run on a fresh connection that lacks the transaction the user
// thinks is open.
//
// Protocol, one JSON object per line. Neovim sends the connection Request
// first; the reply is a Response with Session set, or with Error set (and the
// process exits). Then, in either direction, objects of the form:
//
//	{"id":1,"op":"exec","statements":[{"sql":"...","max_rows":0}],"timeout_ms":30000}
//	{"id":2,"op":"cancel"}
//	{"id":3,"op":"close"}
//
// are answered by one Response carrying the same "id". An exec reply is the
// batch Response of step 1 plus "session" (the connection's state after it);
// if the connection was lost it has "session_lost" and the process exits.
// While an exec runs only cancel and close are accepted.
//
// Nothing is ever committed on the user's behalf. When stdin reaches EOF
// (Neovim exited or crashed) or the process dies, the connection closes and
// the server rolls back whatever transaction was open.

import (
	"bufio"
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-sql-driver/mysql"
)

// SessionState is what the server says about the session's connection.
type SessionState struct {
	ConnectionID  int64  `json:"connection_id"`
	Database      string `json:"database"`
	Autocommit    bool   `json:"autocommit"`
	InTransaction bool   `json:"in_transaction"`
	RowsModified  int64  `json:"rows_modified"`
	RowsLocked    int64  `json:"rows_locked"`
}

// sessionDB is the pinned connection of a session.
type sessionDB interface {
	execer
	// State reads the connection's transaction state from the server.
	State(ctx context.Context) (*SessionState, error)
	// Interrupt aborts the running statement without closing the connection.
	Interrupt() error
	// Close closes the connection, which makes the server roll back an open
	// transaction.
	Close() error
}

// sessionMsg is one line of requests after the connection Request.
type sessionMsg struct {
	ID         int         `json:"id"`
	Op         string      `json:"op"`
	Statements []Statement `json:"statements"`
	TimeoutMs  flexInt     `json:"timeout_ms"`
	err        error       // the line could not be parsed
}

const lostSuffix = " The server rolls back an open transaction when its connection ends, so nothing was committed; " +
	"the session state (variables, autocommit, temporary tables, USE) is gone. The next run opens a new session."

// runServe reads the connection Request from in, opens the session through
// open and serves it until stdin ends, a close request, or a lost connection.
// It returns the process exit code.
func runServe(in io.Reader, out io.Writer, open func(*Request) (sessionDB, *SessionState, error)) int {
	r := bufio.NewReader(in)
	line, err := r.ReadBytes('\n')
	if err != nil {
		writeResponse(out, &Response{Error: "failed to read the connection request: " + err.Error()})
		return 1
	}
	var req Request
	if err := json.Unmarshal(line, &req); err != nil {
		writeResponse(out, &Response{Error: "failed to parse request JSON: " + err.Error()})
		return 1
	}

	db, state, err := open(&req)
	if err != nil {
		writeResponse(out, &Response{Error: err.Error()})
		return 1
	}
	// Closing the connection is what rolls back an open transaction.
	defer db.Close()
	writeResponse(out, &Response{Session: state})

	s := &sessionServer{db: db, out: out}
	return s.serve(readMessages(r))
}

// readMessages turns stdin lines into messages and closes the channel at EOF.
// A final line without its newline is a truncated request and is dropped.
func readMessages(r *bufio.Reader) <-chan sessionMsg {
	msgs := make(chan sessionMsg)
	go func() {
		defer close(msgs)
		for {
			line, err := r.ReadBytes('\n')
			if err != nil {
				return
			}
			var msg sessionMsg
			if err := json.Unmarshal(line, &msg); err != nil {
				msg = sessionMsg{err: err}
			}
			msgs <- msg
		}
	}()
	return msgs
}

type sessionServer struct {
	db  sessionDB
	out io.Writer

	// Per exec: set by the cancel op, read by the statement runner.
	cancelled   atomic.Bool
	interrupted atomic.Bool
	hardCancel  context.CancelFunc
	lostErr     error // written by the exec goroutine, read after it is done
}

func (s *sessionServer) reply(resp *Response) {
	writeResponse(s.out, resp)
}

// serve handles requests until EOF (exit 0), close (exit 0) or a lost
// connection (exit 1).
func (s *sessionServer) serve(msgs <-chan sessionMsg) int {
	for msg := range msgs {
		switch {
		case msg.err != nil:
			s.reply(&Response{Error: "failed to parse request JSON: " + msg.err.Error()})
		case msg.Op == "exec":
			if code, stop := s.exec(msg, msgs); stop {
				return code
			}
		case msg.Op == "cancel":
			// Nothing is running; the statement finished first.
			s.reply(&Response{ID: msg.ID})
		case msg.Op == "close":
			s.reply(&Response{ID: msg.ID})
			return 0
		default:
			s.reply(&Response{ID: msg.ID, Error: fmt.Sprintf("unknown op %q", msg.Op)})
		}
	}
	return 0
}

// exec runs an exec request while still reading stdin, so that cancel and
// close are heard. stop reports that the process must exit with code.
func (s *sessionServer) exec(msg sessionMsg, msgs <-chan sessionMsg) (code int, stop bool) {
	ctx, hardCancel := context.WithCancel(context.Background())
	defer hardCancel()
	s.hardCancel = hardCancel
	s.cancelled.Store(false)
	s.interrupted.Store(false)
	s.lostErr = nil

	done := make(chan *Response, 1)
	go func() { done <- s.runBatch(ctx, msg) }()

	for {
		select {
		case resp := <-done:
			resp.ID = msg.ID
			s.finish(resp)
			return 1, resp.SessionLost
		case m, ok := <-msgs:
			switch {
			case !ok, m.Op == "close":
				// Neovim is gone or detaching: drop the running statement and
				// the connection; the server rolls back.
				hardCancel()
				<-done
				if ok {
					s.reply(&Response{ID: m.ID})
				}
				return 0, true
			case m.err != nil:
				s.reply(&Response{Error: "failed to parse request JSON: " + m.err.Error()})
			case m.Op == "cancel":
				s.cancelled.Store(true)
				resp := &Response{ID: m.ID}
				if err := s.interrupt(); err != nil {
					resp.Error = err.Error()
				}
				s.reply(resp)
			case m.Op == "exec":
				s.reply(&Response{ID: m.ID, Error: "session busy: a statement is still running"})
			default:
				s.reply(&Response{ID: m.ID, Error: fmt.Sprintf("unknown op %q", m.Op)})
			}
		}
	}
}

// interrupt aborts the running statement and keeps the connection. If that is
// impossible (the server can't be reached) the connection is dropped instead,
// which loses the session but still ends in a rollback.
func (s *sessionServer) interrupt() error {
	s.interrupted.Store(true)
	if err := s.db.Interrupt(); err != nil {
		s.hardCancel()
		return fmt.Errorf("could not interrupt the statement (%v); dropping the connection", err)
	}
	return nil
}

// runBatch runs the statements on the pinned connection. Their context has no
// deadline: go-sql-driver closes the socket when a context ends, which would
// lose the session. The timeout is a timer that interrupts the statement.
func (s *sessionServer) runBatch(ctx context.Context, msg sessionMsg) *Response {
	timeout := requestTimeout(&Request{TimeoutMs: msg.TimeoutMs})
	return runStatements(msg.Statements, func(stmt Statement) (*Response, error) {
		if s.cancelled.Load() {
			return nil, errors.New("not run: the batch was cancelled")
		}

		var mu sync.Mutex
		finished, timedOut := false, false
		timer := time.AfterFunc(timeout, func() {
			mu.Lock()
			defer mu.Unlock()
			if !finished {
				timedOut = true
				s.interrupt()
			}
		})
		resp, err := runStatementCtx(ctx, s.db, stmt.SQL, int(stmt.MaxRows), mysqlColumnKind)
		timer.Stop()
		mu.Lock()
		finished = true
		mu.Unlock()

		switch {
		case err == nil:
		case ctx.Err() != nil || isConnLost(err):
			s.lostErr = err
		case timedOut:
			err = fmt.Errorf("timed out after %s and was interrupted: %w", timeout, err)
		case s.cancelled.Load():
			err = fmt.Errorf("cancelled: %w", err)
		}
		return resp, err
	})
}

// finish adds the connection's state to an exec reply and writes it. If the
// connection is gone, or its state can't be read (then the session can't be
// trusted to show an open transaction), the session is declared lost.
func (s *sessionServer) finish(resp *Response) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	state, err := s.db.State(ctx)

	switch {
	case s.lostErr != nil:
		resp.Error = fmt.Sprintf("Session lost: %v.%s", s.lostErr, lostSuffix)
		resp.SessionLost = true
	case err != nil:
		resp.Error = fmt.Sprintf("Session closed: the transaction state could not be read (%v).%s", err, lostSuffix)
		resp.SessionLost = true
	default:
		resp.Session = state
		if resp.Error != "" && state.InTransaction {
			resp.Error += fmt.Sprintf(" A transaction is still open (%d rows modified).", state.RowsModified)
		} else if resp.Error != "" && s.interrupted.Load() {
			resp.Error += " No transaction is open."
		}
	}
	s.reply(resp)
}

// isConnLost reports whether err means the connection itself is unusable
// (as opposed to the statement failing).
func isConnLost(err error) bool {
	var netErr net.Error
	var myErr *mysql.MySQLError
	switch {
	case errors.Is(err, driver.ErrBadConn), errors.Is(err, sql.ErrConnDone), errors.Is(err, mysql.ErrInvalidConn),
		errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, net.ErrClosed):
		return true
	case errors.As(err, &netErr):
		return true
	case errors.As(err, &myErr):
		// Server shutdown, connection killed, idle (wait_timeout) disconnect.
		return myErr.Number == 1053 || myErr.Number == 1927 || myErr.Number == 4031
	}
	return false
}

// openSession opens the session for the request's engine.
func openSession(req *Request) (sessionDB, *SessionState, error) {
	switch req.Engine {
	case "", "mysql":
		return openMySQLSession(req)
	default:
		return nil, nil, fmt.Errorf("persistent sessions are MySQL-only (engine %q)", req.Engine)
	}
}
