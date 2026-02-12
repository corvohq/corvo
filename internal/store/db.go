package store

import (
	"database/sql"
	"embed"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	_ "github.com/mattn/go-sqlite3"
)

//go:embed migrations/*.sql
var migrations embed.FS

// DB holds separate write and read database connections.
// The write connection is limited to 1 open conn to serialize writes (SQLite requirement).
// The read pool allows concurrent reads via WAL mode.
type DB struct {
	Write *sql.DB
	Read  *sql.DB
}

// Open creates or opens a SQLite database at dataDir/jobbie.db.
// It configures WAL mode, synchronous=FULL, foreign_keys=ON,
// and runs any pending migrations.
func Open(dataDir string) (*DB, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "jobbie.db")

	writeDB, err := openConn(dbPath)
	if err != nil {
		return nil, fmt.Errorf("open write connection: %w", err)
	}
	writeDB.SetMaxOpenConns(1)

	readDB, err := openConn(dbPath)
	if err != nil {
		writeDB.Close()
		return nil, fmt.Errorf("open read connection: %w", err)
	}

	db := &DB{Write: writeDB, Read: readDB}

	if err := db.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("run migrations: %w", err)
	}

	slog.Info("database opened", "path", dbPath)
	return db, nil
}

func openConn(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", path+"?_journal_mode=WAL&_synchronous=NORMAL&_foreign_keys=ON&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func (db *DB) migrate() error {
	// Ensure schema_migrations table exists (bootstrap)
	_, err := db.Write.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version    INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
	)`)
	if err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	var current int
	err = db.Write.QueryRow("SELECT COALESCE(MAX(version), 0) FROM schema_migrations").Scan(&current)
	if err != nil {
		return fmt.Errorf("get current migration version: %w", err)
	}

	// For now we only have migration 001
	if current >= 1 {
		slog.Debug("migrations up to date", "version", current)
		return nil
	}

	sqlBytes, err := migrations.ReadFile("migrations/001_initial.sql")
	if err != nil {
		return fmt.Errorf("read migration 001: %w", err)
	}

	tx, err := db.Write.Begin()
	if err != nil {
		return fmt.Errorf("begin migration tx: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.Exec(string(sqlBytes)); err != nil {
		return fmt.Errorf("execute migration 001: %w", err)
	}

	if _, err := tx.Exec("INSERT INTO schema_migrations (version) VALUES (?)", 1); err != nil {
		return fmt.Errorf("record migration 001: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migration 001: %w", err)
	}

	slog.Info("applied migration", "version", 1)
	return nil
}

// Close closes both write and read database connections.
func (db *DB) Close() error {
	var errs []error
	if err := db.Write.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close write db: %w", err))
	}
	if err := db.Read.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close read db: %w", err))
	}
	if len(errs) > 0 {
		return errs[0]
	}
	return nil
}
