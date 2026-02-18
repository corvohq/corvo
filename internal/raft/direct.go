package raft

import (
	"database/sql"
	"path/filepath"
	"sync"
	"time"

	"github.com/cockroachdb/pebble"
	hashraft "github.com/hashicorp/raft"
	"github.com/corvohq/corvo/internal/store"
)

// DirectApplier applies operations directly through the FSM without Raft networking.
// Useful for testing and single-node non-HA operation.
type DirectApplier struct {
	fsm          *FSM
	pdb          *pebble.DB
	sqlite       *sql.DB
	pendingCache sync.Map
}

// NewDirectApplier creates a DirectApplier with Pebble and SQLite in dataDir.
func NewDirectApplier(dataDir string) (*DirectApplier, error) {
	pebbleDir := filepath.Join(dataDir, "pebble")
	pdb, err := pebble.Open(pebbleDir, &pebble.Options{})
	if err != nil {
		return nil, err
	}

	sqlitePath := filepath.Join(dataDir, "corvo.db")
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

// HasPendingJobs checks the in-memory cache for pending jobs.
// Returns true on cache miss (assumes pending) to avoid expensive Pebble scans.
func (d *DirectApplier) HasPendingJobs(queues []string) bool {
	now := time.Now().UnixNano()
	for _, q := range queues {
		if entry, ok := d.pendingCache.Load(q); ok {
			e := entry.(pendingCacheEntry)
			if now < e.deadline {
				if e.hasPending {
					return true
				}
				continue
			}
		}
		return true // cache miss → assume pending
	}
	return false
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
