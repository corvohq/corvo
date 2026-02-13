package raft

import (
	"archive/tar"
	"compress/gzip"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/cockroachdb/pebble"
	"github.com/hashicorp/raft"
)

// fsmSnapshot implements raft.FSMSnapshot.
type fsmSnapshot struct {
	pebble *pebble.DB
	sqlite *sql.DB
}

func (s *fsmSnapshot) Persist(sink raft.SnapshotSink) error {
	defer sink.Close()

	gzw := gzip.NewWriter(sink)
	tw := tar.NewWriter(gzw)

	// 1. Pebble checkpoint
	tmpDir, err := os.MkdirTemp("", "jobbie-snapshot-*")
	if err != nil {
		sink.Cancel()
		return fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	checkpointDir := filepath.Join(tmpDir, "pebble-checkpoint")
	if err := s.pebble.Checkpoint(checkpointDir); err != nil {
		sink.Cancel()
		return fmt.Errorf("pebble checkpoint: %w", err)
	}

	// Add pebble checkpoint files to tar
	err = filepath.Walk(checkpointDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		relPath, _ := filepath.Rel(checkpointDir, path)
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		header.Name = "pebble/" + relPath
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(tw, f)
		return err
	})
	if err != nil {
		sink.Cancel()
		return fmt.Errorf("tar pebble checkpoint: %w", err)
	}

	// 2. SQLite backup via VACUUM INTO
	sqliteBackup := filepath.Join(tmpDir, "sqlite-backup.db")
	if _, err := s.sqlite.Exec("VACUUM INTO ?", sqliteBackup); err != nil {
		sink.Cancel()
		return fmt.Errorf("sqlite vacuum into: %w", err)
	}

	info, err := os.Stat(sqliteBackup)
	if err != nil {
		sink.Cancel()
		return fmt.Errorf("stat sqlite backup: %w", err)
	}
	header := &tar.Header{
		Name: "sqlite/jobbie.db",
		Size: info.Size(),
		Mode: 0644,
	}
	if err := tw.WriteHeader(header); err != nil {
		sink.Cancel()
		return err
	}
	f, err := os.Open(sqliteBackup)
	if err != nil {
		sink.Cancel()
		return err
	}
	if _, err := io.Copy(tw, f); err != nil {
		f.Close()
		sink.Cancel()
		return err
	}
	f.Close()

	if err := tw.Close(); err != nil {
		sink.Cancel()
		return err
	}
	return gzw.Close()
}

func (s *fsmSnapshot) Release() {}

// restoreFromSnapshot restores Pebble and SQLite from a snapshot tar.gz stream.
func restoreFromSnapshot(pdb *pebble.DB, sqliteDB *sql.DB, rc io.Reader) error {
	tmpDir, err := os.MkdirTemp("", "jobbie-restore-*")
	if err != nil {
		return fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	gzr, err := gzip.NewReader(rc)
	if err != nil {
		return fmt.Errorf("gzip reader: %w", err)
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar read: %w", err)
		}

		target := filepath.Join(tmpDir, header.Name)
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		f, err := os.Create(target)
		if err != nil {
			return err
		}
		if _, err := io.Copy(f, tr); err != nil {
			f.Close()
			return err
		}
		f.Close()
	}

	// Restore Pebble: iterate snapshot and ingest
	pebbleDir := filepath.Join(tmpDir, "pebble")
	if _, err := os.Stat(pebbleDir); err == nil {
		// Open the snapshot as a read-only Pebble DB and copy all keys
		snapDB, err := pebble.Open(pebbleDir, &pebble.Options{ReadOnly: true})
		if err != nil {
			return fmt.Errorf("open snapshot pebble: %w", err)
		}

		// Clear existing data
		iter, err := pdb.NewIter(nil)
		if err != nil {
			snapDB.Close()
			return fmt.Errorf("create clear iter: %w", err)
		}
		batch := pdb.NewBatch()
		for iter.First(); iter.Valid(); iter.Next() {
			k := make([]byte, len(iter.Key()))
			copy(k, iter.Key())
			batch.Delete(k, pebble.Sync)
		}
		iter.Close()
		if err := batch.Commit(pebble.Sync); err != nil {
			snapDB.Close()
			return fmt.Errorf("clear pebble: %w", err)
		}

		// Copy from snapshot
		snapIter, err := snapDB.NewIter(nil)
		if err != nil {
			snapDB.Close()
			return fmt.Errorf("create snapshot iter: %w", err)
		}
		batch = pdb.NewBatch()
		for snapIter.First(); snapIter.Valid(); snapIter.Next() {
			k := make([]byte, len(snapIter.Key()))
			copy(k, snapIter.Key())
			v := make([]byte, len(snapIter.Value()))
			copy(v, snapIter.Value())
			batch.Set(k, v, pebble.Sync)
		}
		snapIter.Close()
		snapDB.Close()

		if err := batch.Commit(pebble.Sync); err != nil {
			return fmt.Errorf("restore pebble: %w", err)
		}
	}

	// Restore SQLite: exec from backup
	sqlitePath := filepath.Join(tmpDir, "sqlite", "jobbie.db")
	if _, err := os.Stat(sqlitePath); err == nil {
		// Read the tables from the backup and apply to current DB
		backupDB, err := sql.Open("sqlite", sqlitePath)
		if err != nil {
			return fmt.Errorf("open backup sqlite: %w", err)
		}
		defer backupDB.Close()

		// Get all table names from backup
		rows, err := backupDB.Query(`
			SELECT name FROM sqlite_master
			WHERE type='table'
			  AND name NOT LIKE 'sqlite_%'
			  AND name != 'schema_migrations'
			  AND name NOT LIKE 'jobs_fts%'
		`)
		if err != nil {
			return fmt.Errorf("list backup tables: %w", err)
		}
		var tables []string
		for rows.Next() {
			var name string
			rows.Scan(&name)
			tables = append(tables, name)
		}
		rows.Close()

		// Clear and repopulate each table
		for _, table := range tables {
			sqliteDB.Exec("DELETE FROM " + table)
		}

		// For each table, read all rows from backup and insert into main
		for _, table := range tables {
			if err := copyTable(backupDB, sqliteDB, table); err != nil {
				slog.Error("restore table failed", "table", table, "error", err)
			}
		}
	}

	return nil
}

func copyTable(src, dst *sql.DB, table string) error {
	rows, err := src.Query("SELECT * FROM " + table)
	if err != nil {
		return err
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return err
	}

	placeholders := make([]string, len(cols))
	for i := range placeholders {
		placeholders[i] = "?"
	}
	insertSQL := fmt.Sprintf("INSERT OR REPLACE INTO %s (%s) VALUES (%s)",
		table,
		strings.Join(cols, ", "),
		strings.Join(placeholders, ", "))

	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		if _, err := dst.Exec(insertSQL, vals...); err != nil {
			return err
		}
	}
	return rows.Err()
}
