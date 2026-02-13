package raft

import (
	"database/sql"
	"path/filepath"

	"github.com/cockroachdb/pebble"
	hashraft "github.com/hashicorp/raft"
	"github.com/user/jobbie/internal/store"
)

// DirectApplier applies operations directly through the FSM without Raft networking.
// Useful for testing and single-node non-HA operation.
type DirectApplier struct {
	fsm    *FSM
	pdb    *pebble.DB
	sqlite *sql.DB
}

// NewDirectApplier creates a DirectApplier with Pebble and SQLite in dataDir.
func NewDirectApplier(dataDir string) (*DirectApplier, error) {
	pebbleDir := filepath.Join(dataDir, "pebble")
	pdb, err := pebble.Open(pebbleDir, &pebble.Options{})
	if err != nil {
		return nil, err
	}

	sqlitePath := filepath.Join(dataDir, "jobbie.db")
	sqliteDB, err := openMaterializedView(sqlitePath)
	if err != nil {
		pdb.Close()
		return nil, err
	}

	return &DirectApplier{
		fsm:    NewFSM(pdb, sqliteDB),
		pdb:    pdb,
		sqlite: sqliteDB,
	}, nil
}

// Apply implements store.Applier.
func (d *DirectApplier) Apply(opType store.OpType, data any) *store.OpResult {
	opBytes, err := store.MarshalOp(opType, data)
	if err != nil {
		return &store.OpResult{Err: err}
	}
	result := d.fsm.Apply(&hashraft.Log{Data: opBytes})
	return result.(*store.OpResult)
}

// SQLiteDB returns the SQLite database for read access.
func (d *DirectApplier) SQLiteDB() *sql.DB {
	return d.sqlite
}

// Close closes both Pebble and SQLite.
func (d *DirectApplier) Close() error {
	d.fsm.Close()
	d.pdb.Close()
	d.sqlite.Close()
	return nil
}
