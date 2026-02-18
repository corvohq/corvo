package store_test

import (
	"encoding/json"
	"testing"

	"github.com/corvohq/corvo/internal/store"
)

func TestHoldApproveFlow(t *testing.T) {
	s := testStore(t)

	enq, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "held.flow",
		Payload: json.RawMessage(`{"kind":"review"}`),
	})
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	if err := s.HoldJob(enq.JobID); err != nil {
		t.Fatalf("hold: %v", err)
	}
	job, err := s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("get held job: %v", err)
	}
	if job.State != store.StateHeld {
		t.Fatalf("state = %q, want %q", job.State, store.StateHeld)
	}

	// Held job should not be fetched.
	got, err := s.Fetch(store.FetchRequest{
		Queues:   []string{"held.flow"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("fetch while held: %v", err)
	}
	if got != nil {
		t.Fatalf("fetch got job %s, want nil", got.JobID)
	}

	if err := s.ApproveJob(enq.JobID); err != nil {
		t.Fatalf("approve: %v", err)
	}
	job, err = s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("get approved job: %v", err)
	}
	if job.State != store.StatePending {
		t.Fatalf("state = %q, want %q", job.State, store.StatePending)
	}

	got, err = s.Fetch(store.FetchRequest{
		Queues:   []string{"held.flow"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("fetch after approve: %v", err)
	}
	if got == nil || got.JobID != enq.JobID {
		t.Fatalf("fetch returned %+v, want job %s", got, enq.JobID)
	}
}

func TestRejectHeldJobToDead(t *testing.T) {
	s := testStore(t)

	enq, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "held.reject",
		Payload: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	if err := s.HoldJob(enq.JobID); err != nil {
		t.Fatalf("hold: %v", err)
	}
	if err := s.RejectJob(enq.JobID); err != nil {
		t.Fatalf("reject: %v", err)
	}

	job, err := s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("get rejected job: %v", err)
	}
	if job.State != store.StateDead {
		t.Fatalf("state = %q, want %q", job.State, store.StateDead)
	}
	if job.FailedAt == nil {
		t.Fatal("failed_at is nil, want set")
	}
}

