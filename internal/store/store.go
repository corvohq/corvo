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
}

// NewStore creates a new Store with the given DB.
// It uses a DirectWriter that writes to SQLite immediately.
func NewStore(db *DB) *Store {
	return &Store{
		db:     db,
		writer: &DirectWriter{db: db.Write},
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
