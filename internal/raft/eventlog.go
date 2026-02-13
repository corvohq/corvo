package raft

import (
	"encoding/json"
	"fmt"

	"github.com/cockroachdb/pebble"
	"github.com/user/jobbie/internal/kv"
)

type lifecycleEvent struct {
	Seq   uint64 `json:"seq"`
	Type  string `json:"type"`
	JobID string `json:"job_id,omitempty"`
	Queue string `json:"queue,omitempty"`
	AtNs  uint64 `json:"at_ns"`
}

func loadEventCursor(db *pebble.DB) uint64 {
	val, closer, err := db.Get(kv.EventCursorKey())
	if err != nil {
		return 0
	}
	defer closer.Close()
	if len(val) < 8 {
		return 0
	}
	return kv.GetUint64BE(val)
}

func (f *FSM) appendLifecycleEvent(batch *pebble.Batch, typ, jobID, queue string, atNs uint64) error {
	if !f.lifecycleOn {
		return nil
	}
	f.eventSeq++
	ev := lifecycleEvent{
		Seq:   f.eventSeq,
		Type:  typ,
		JobID: jobID,
		Queue: queue,
		AtNs:  atNs,
	}
	data, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("marshal lifecycle event: %w", err)
	}
	if err := batch.Set(kv.EventLogKey(f.eventSeq), data, f.writeOpts); err != nil {
		return fmt.Errorf("set event log key: %w", err)
	}
	return nil
}

func (f *FSM) appendLifecycleCursor(batch *pebble.Batch) error {
	if !f.lifecycleOn {
		return nil
	}
	cursor := kv.PutUint64BE(nil, f.eventSeq)
	if err := batch.Set(kv.EventCursorKey(), cursor, f.writeOpts); err != nil {
		return fmt.Errorf("set event cursor: %w", err)
	}
	return nil
}
