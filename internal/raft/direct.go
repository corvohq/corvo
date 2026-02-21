package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"sync"
	"time"

	"github.com/cockroachdb/pebble"
	hashraft "github.com/hashicorp/raft"
	"github.com/corvohq/corvo/internal/kv"
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
		_ = pdb.Close()
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

// FlushSQLiteMirror blocks until all queued async SQLite mirror writes have
// been flushed. Implements store.Applier.
func (d *DirectApplier) FlushSQLiteMirror() {
	d.fsm.FlushSQLiteMirror()
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

// SetSQLiteMirrorAsync toggles async SQLite mirror mode on the underlying FSM.
func (d *DirectApplier) SetSQLiteMirrorAsync(async bool) {
	d.fsm.SetSQLiteMirrorAsync(async)
}

// SQLiteDB returns the SQLite database for read access.
func (d *DirectApplier) SQLiteDB() *sql.DB {
	return d.sqlite
}

// SetLifecycleEventsEnabled toggles lifecycle event persistence on the underlying FSM.
func (d *DirectApplier) SetLifecycleEventsEnabled(enabled bool) {
	d.fsm.SetLifecycleEventsEnabled(enabled)
}

// EventLog reads lifecycle events from Pebble with sequence > afterSeq.
func (d *DirectApplier) EventLog(afterSeq uint64, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}

	start := afterSeq + 1
	iter, err := d.pdb.NewIter(&pebble.IterOptions{
		LowerBound: kv.EventLogKey(start),
	})
	if err != nil {
		return nil, err
	}
	defer func() { _ = iter.Close() }()

	prefix := kv.EventLogPrefix()
	events := make([]map[string]any, 0, limit)
	for iter.First(); iter.Valid() && len(events) < limit; iter.Next() {
		if !bytes.HasPrefix(iter.Key(), prefix) {
			break
		}
		var ev lifecycleEvent
		if err := json.Unmarshal(iter.Value(), &ev); err != nil {
			continue
		}
		item := map[string]any{
			"seq":   ev.Seq,
			"type":  ev.Type,
			"at_ns": ev.AtNs,
		}
		if ev.JobID != "" {
			item["job_id"] = ev.JobID
		}
		if ev.Queue != "" {
			item["queue"] = ev.Queue
		}
		if len(ev.Data) > 0 {
			item["data"] = ev.Data
		}
		events = append(events, item)
	}
	if err := iter.Error(); err != nil {
		return nil, err
	}
	return events, nil
}

// Close closes both Pebble and SQLite.
func (d *DirectApplier) Close() error {
	d.fsm.Close()
	_ = d.pdb.Close()
	_ = d.sqlite.Close()
	return nil
}
