package store

import (
	"database/sql"
	"fmt"
)

// Writer abstracts write operations so Raft can be inserted later.
// For Phase 1 (single-node), DirectWriter executes against SQLite directly.
type Writer interface {
	Execute(query string, args ...interface{}) (sql.Result, error)
	ExecuteTx(fn func(tx *sql.Tx) error) error
}

// Store is the main data access layer for Jobbie.
type Store struct {
	db     *DB
	writer Writer
	async  *AsyncWriter

	// Prepared statements for hot path
	stmtInsertJob    *sql.Stmt
	stmtCheckUnique  *sql.Stmt
	stmtInsertUnique *sql.Stmt
}

// NewStore creates a new Store with the given DB.
// It uses a DirectWriter that writes to SQLite immediately.
func NewStore(db *DB) *Store {
	s := &Store{
		db:     db,
		writer: &DirectWriter{db: db.Write},
		async:  NewAsyncWriter(db.Write),
	}
	s.prepareStatements()
	return s
}

// NewStoreWithWriter creates a Store with a custom Writer (e.g. BatchWriter).
func NewStoreWithWriter(db *DB, writer Writer) *Store {
	s := &Store{
		db:     db,
		writer: writer,
		async:  NewAsyncWriter(db.Write),
	}
	s.prepareStatements()
	return s
}

func (s *Store) prepareStatements() {
	var err error

	s.stmtInsertJob, err = s.db.Write.Prepare(
		`INSERT INTO jobs (id, queue, state, payload, priority, max_retries, retry_backoff, retry_base_delay_ms, retry_max_delay_ms, unique_key, tags, scheduled_at, expire_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
	if err != nil {
		panic(fmt.Sprintf("prepare insert job: %v", err))
	}

	s.stmtCheckUnique, err = s.db.Write.Prepare(
		`SELECT job_id FROM unique_locks WHERE queue = ? AND unique_key = ? AND expires_at > strftime('%Y-%m-%dT%H:%M:%f', 'now')`,
	)
	if err != nil {
		panic(fmt.Sprintf("prepare check unique: %v", err))
	}

	s.stmtInsertUnique, err = s.db.Write.Prepare(
		`INSERT OR REPLACE INTO unique_locks (queue, unique_key, job_id, expires_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f', 'now', '+' || ? || ' seconds'))`,
	)
	if err != nil {
		panic(fmt.Sprintf("prepare insert unique: %v", err))
	}
}

// Close stops the async writer and closes prepared statements.
func (s *Store) Close() error {
	if s.async != nil {
		s.async.Stop()
	}
	if s.stmtInsertJob != nil {
		s.stmtInsertJob.Close()
	}
	if s.stmtCheckUnique != nil {
		s.stmtCheckUnique.Close()
	}
	if s.stmtInsertUnique != nil {
		s.stmtInsertUnique.Close()
	}
	return nil
}

// FlushAsync blocks until all pending async operations have been executed.
func (s *Store) FlushAsync() {
	if s.async != nil {
		s.async.Flush()
	}
}

// DirectWriter executes SQL directly against the SQLite write connection.
type DirectWriter struct {
	db *sql.DB
}

func (w *DirectWriter) Execute(query string, args ...interface{}) (sql.Result, error) {
	return w.db.Exec(query, args...)
}

func (w *DirectWriter) ExecuteTx(fn func(tx *sql.Tx) error) error {
	tx, err := w.db.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	if err := fn(tx); err != nil {
		return err
	}

	return tx.Commit()
}

// ReadDB returns the read database connection for queries.
func (s *Store) ReadDB() *sql.DB {
	return s.db.Read
}
