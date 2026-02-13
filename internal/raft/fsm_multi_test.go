package raft

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/user/jobbie/internal/store"
)

func makeEnqueueOp(jobID, queue string, now time.Time) store.EnqueueOp {
	return store.EnqueueOp{
		JobID:       jobID,
		Queue:       queue,
		State:       store.StatePending,
		Payload:     json.RawMessage(`{"ok":true}`),
		Priority:    store.PriorityNormal,
		MaxRetries:  3,
		Backoff:     store.BackoffExponential,
		BaseDelayMs: 5000,
		MaxDelayMs:  600000,
		CreatedAt:   now.UTC(),
		NowNs:       uint64(now.UnixNano()),
	}
}

func TestApplyMultiEnqueueFastPath(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	now := time.Now()
	e1 := makeEnqueueOp(store.NewJobID(), "multi.q", now)
	e2 := makeEnqueueOp(store.NewJobID(), "multi.q", now)

	op1, err := store.BuildOp(store.OpEnqueue, e1)
	if err != nil {
		t.Fatalf("BuildOp op1: %v", err)
	}
	op2, err := store.BuildOp(store.OpEnqueue, e2)
	if err != nil {
		t.Fatalf("BuildOp op2: %v", err)
	}

	res := da.Apply(store.OpMulti, store.MultiOp{Ops: []store.Op{op1, op2}})
	if res.Err != nil {
		t.Fatalf("Apply OpMulti: %v", res.Err)
	}

	subResults, ok := res.Data.([]*store.OpResult)
	if !ok {
		t.Fatalf("unexpected multi result type: %T", res.Data)
	}
	if len(subResults) != 2 {
		t.Fatalf("sub result count = %d, want 2", len(subResults))
	}
	for i, sr := range subResults {
		if sr.Err != nil {
			t.Fatalf("sub result %d err: %v", i, sr.Err)
		}
		out, ok := sr.Data.(*store.EnqueueResult)
		if !ok {
			t.Fatalf("sub result %d data type: %T", i, sr.Data)
		}
		if out.UniqueExisting {
			t.Fatalf("sub result %d unexpectedly unique_existing", i)
		}
	}

	s := store.NewStore(da, da.SQLiteDB())
	defer s.Close()
	if _, err := s.GetJob(e1.JobID); err != nil {
		t.Fatalf("GetJob e1: %v", err)
	}
	if _, err := s.GetJob(e2.JobID); err != nil {
		t.Fatalf("GetJob e2: %v", err)
	}
}

func TestApplyMultiEnqueueUniqueDuplicateSameBatch(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	now := time.Now()
	e1 := makeEnqueueOp(store.NewJobID(), "multi.unique.q", now)
	e1.UniqueKey = "u1"
	e1.UniquePeriod = 60
	e2 := makeEnqueueOp(store.NewJobID(), "multi.unique.q", now)
	e2.UniqueKey = "u1"
	e2.UniquePeriod = 60

	op1, err := store.BuildOp(store.OpEnqueue, e1)
	if err != nil {
		t.Fatalf("BuildOp op1: %v", err)
	}
	op2, err := store.BuildOp(store.OpEnqueue, e2)
	if err != nil {
		t.Fatalf("BuildOp op2: %v", err)
	}

	res := da.Apply(store.OpMulti, store.MultiOp{Ops: []store.Op{op1, op2}})
	if res.Err != nil {
		t.Fatalf("Apply OpMulti: %v", res.Err)
	}
	subResults := res.Data.([]*store.OpResult)
	if len(subResults) != 2 {
		t.Fatalf("sub result count = %d, want 2", len(subResults))
	}
	r1 := subResults[0].Data.(*store.EnqueueResult)
	r2 := subResults[1].Data.(*store.EnqueueResult)

	if r1.UniqueExisting {
		t.Fatalf("first enqueue should not be duplicate")
	}
	if !r2.UniqueExisting {
		t.Fatalf("second enqueue should be duplicate")
	}
	if r2.JobID != e1.JobID {
		t.Fatalf("duplicate job id = %s, want %s", r2.JobID, e1.JobID)
	}

	s := store.NewStore(da, da.SQLiteDB())
	defer s.Close()
	if _, err := s.GetJob(e1.JobID); err != nil {
		t.Fatalf("GetJob first: %v", err)
	}
	if _, err := s.GetJob(e2.JobID); err == nil {
		t.Fatalf("second job should not exist")
	}
}

func TestApplyMultiEnqueueBatchFastPath(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	now := time.Now()
	b1j1 := makeEnqueueOp(store.NewJobID(), "multi.batch.q", now)
	b1j2 := makeEnqueueOp(store.NewJobID(), "multi.batch.q", now)
	b2j1 := makeEnqueueOp(store.NewJobID(), "multi.batch.q", now)
	b2j2 := makeEnqueueOp(store.NewJobID(), "multi.batch.q", now)

	batch1 := store.EnqueueBatchOp{Jobs: []store.EnqueueOp{b1j1, b1j2}}
	batch2 := store.EnqueueBatchOp{Jobs: []store.EnqueueOp{b2j1, b2j2}}

	op1, err := store.BuildOp(store.OpEnqueueBatch, batch1)
	if err != nil {
		t.Fatalf("BuildOp batch1: %v", err)
	}
	op2, err := store.BuildOp(store.OpEnqueueBatch, batch2)
	if err != nil {
		t.Fatalf("BuildOp batch2: %v", err)
	}

	res := da.Apply(store.OpMulti, store.MultiOp{Ops: []store.Op{op1, op2}})
	if res.Err != nil {
		t.Fatalf("Apply OpMulti: %v", res.Err)
	}
	subResults, ok := res.Data.([]*store.OpResult)
	if !ok {
		t.Fatalf("unexpected multi result type: %T", res.Data)
	}
	if len(subResults) != 2 {
		t.Fatalf("sub result count = %d, want 2", len(subResults))
	}
	for i, sr := range subResults {
		if sr.Err != nil {
			t.Fatalf("sub result %d err: %v", i, sr.Err)
		}
		out, ok := sr.Data.(*store.BatchEnqueueResult)
		if !ok {
			t.Fatalf("sub result %d data type: %T", i, sr.Data)
		}
		if len(out.JobIDs) != 2 {
			t.Fatalf("sub result %d job_ids = %d, want 2", i, len(out.JobIDs))
		}
	}

	s := store.NewStore(da, da.SQLiteDB())
	defer s.Close()
	for _, id := range []string{b1j1.JobID, b1j2.JobID, b2j1.JobID, b2j2.JobID} {
		if _, err := s.GetJob(id); err != nil {
			t.Fatalf("GetJob %s: %v", id, err)
		}
	}
}
