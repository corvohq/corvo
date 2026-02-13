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
// EventsWrite is a separate SQLite database for events/stats to avoid write lock contention.
type DB struct {
	Write       *sql.DB
	Read        *sql.DB
	EventsWrite *sql.DB
}

// Open creates or opens a SQLite database at dataDir/jobbie.db.
// It configures WAL mode, synchronous=NORMAL, foreign_keys=ON,
// and runs any pending migrations.
// A separate events.db is created for events/stats to avoid write lock contention.
func Open(dataDir string) (*DB, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}

	dbPath := filepath.Join(dataDir, "jobbie.db")
	eventsPath := filepath.Join(dataDir, "events.db")

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

	eventsDB, err := openConn(eventsPath)
	if err != nil {
		writeDB.Close()
		readDB.Close()
		return nil, fmt.Errorf("open events connection: %w", err)
	}
	eventsDB.SetMaxOpenConns(1)

	db := &DB{Write: writeDB, Read: readDB, EventsWrite: eventsDB}

	if err := db.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("run migrations: %w", err)
	}

	if err := db.migrateEvents(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate events db: %w", err)
	}

	// ATTACH events DB to read connection for cross-database JOINs.
	if _, err := readDB.Exec("ATTACH DATABASE ? AS edb", eventsPath); err != nil {
		db.Close()
		return nil, fmt.Errorf("attach events db: %w", err)
	}

	slog.Info("database opened", "path", dbPath, "events_path", eventsPath)
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

// migrateEvents creates the events/stats tables in the events database.
func (db *DB) migrateEvents() error {
	_, err := db.EventsWrite.Exec(`
		CREATE TABLE IF NOT EXISTS events (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			type       TEXT NOT NULL,
			job_id     TEXT,
			queue      TEXT,
			data       TEXT,
			created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
		);
		CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);

		CREATE TABLE IF NOT EXISTS queue_stats (
			queue      TEXT PRIMARY KEY,
			enqueued   INTEGER NOT NULL DEFAULT 0,
			completed  INTEGER NOT NULL DEFAULT 0,
			failed     INTEGER NOT NULL DEFAULT 0,
			dead       INTEGER NOT NULL DEFAULT 0
		);
	`)
	return err
}

// Close closes all database connections.
func (db *DB) Close() error {
	var errs []error
	if err := db.Write.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close write db: %w", err))
	}
	if err := db.Read.Close(); err != nil {
		errs = append(errs, fmt.Errorf("close read db: %w", err))
	}
	if db.EventsWrite != nil {
		if err := db.EventsWrite.Close(); err != nil {
			errs = append(errs, fmt.Errorf("close events db: %w", err))
		}
	}
	if len(errs) > 0 {
		return errs[0]
	}
	return nil
}
