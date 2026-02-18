package store_test

import (
	"encoding/json"
	"testing"

	"github.com/corvohq/corvo/internal/search"
	"github.com/corvohq/corvo/internal/store"
)

func TestBulkRetryByIDs(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	var deadIDs []string
	for range 3 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.retry", Payload: json.RawMessage(`{}`), MaxRetries: &maxRetries})
		s.Fetch(store.FetchRequest{Queues: []string{"bulk.retry"}, WorkerID: "w", Hostname: "h"})
		s.Fail(r.JobID, "err", "", false)
		deadIDs = append(deadIDs, r.JobID)
	}

	result, err := s.BulkAction(store.BulkRequest{JobIDs: deadIDs, Action: "retry"})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 3 {
		t.Errorf("affected = %d, want 3", result.Affected)
	}

	// Verify all are pending
	for _, id := range deadIDs {
		j, _ := s.GetJob(id)
		if j.State != store.StatePending {
			t.Errorf("job %s state = %q, want pending", id, j.State)
		}
	}
}

func TestBulkDeleteByIDs(t *testing.T) {
	s := testStore(t)

	var ids []string
	for range 3 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.del", Payload: json.RawMessage(`{}`)})
		ids = append(ids, r.JobID)
	}

	result, err := s.BulkAction(store.BulkRequest{JobIDs: ids, Action: "delete"})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 3 {
		t.Errorf("affected = %d, want 3", result.Affected)
	}
}

func TestBulkCancelByIDs(t *testing.T) {
	s := testStore(t)

	var ids []string
	for range 2 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.cancel", Payload: json.RawMessage(`{}`)})
		ids = append(ids, r.JobID)
	}

	result, err := s.BulkAction(store.BulkRequest{JobIDs: ids, Action: "cancel"})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 2 {
		t.Errorf("affected = %d, want 2", result.Affected)
	}
}

func TestBulkMove(t *testing.T) {
	s := testStore(t)

	var ids []string
	for range 2 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.src", Payload: json.RawMessage(`{}`)})
		ids = append(ids, r.JobID)
	}

	result, err := s.BulkAction(store.BulkRequest{
		JobIDs:      ids,
		Action:      "move",
		MoveToQueue: "bulk.dst",
	})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 2 {
		t.Errorf("affected = %d, want 2", result.Affected)
	}

	j, _ := s.GetJob(ids[0])
	if j.Queue != "bulk.dst" {
		t.Errorf("queue = %q, want bulk.dst", j.Queue)
	}
}

func TestBulkChangePriority(t *testing.T) {
	s := testStore(t)

	var ids []string
	for range 2 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.prio", Payload: json.RawMessage(`{}`)})
		ids = append(ids, r.JobID)
	}

	result, err := s.BulkAction(store.BulkRequest{
		JobIDs:   ids,
		Action:   "change_priority",
		Priority: "critical",
	})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 2 {
		t.Errorf("affected = %d, want 2", result.Affected)
	}

	j, _ := s.GetJob(ids[0])
	if j.Priority != store.PriorityCritical {
		t.Errorf("priority = %d, want %d", j.Priority, store.PriorityCritical)
	}
}

func TestBulkByFilter(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	for range 3 {
		r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.filter", Payload: json.RawMessage(`{}`), MaxRetries: &maxRetries})
		s.Fetch(store.FetchRequest{Queues: []string{"bulk.filter"}, WorkerID: "w", Hostname: "h"})
		s.Fail(r.JobID, "err", "", false)
	}

	filter := search.Filter{Queue: "bulk.filter", State: []string{"dead"}}
	result, err := s.BulkAction(store.BulkRequest{Filter: &filter, Action: "retry"})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 3 {
		t.Errorf("affected = %d, want 3", result.Affected)
	}
}

func TestBulkEmptyResult(t *testing.T) {
	s := testStore(t)

	result, err := s.BulkAction(store.BulkRequest{JobIDs: []string{}, Action: "retry"})
	if err != nil {
		t.Fatalf("BulkAction: %v", err)
	}
	if result.Affected != 0 {
		t.Errorf("affected = %d, want 0", result.Affected)
	}
}

func TestBulkUnknownAction(t *testing.T) {
	s := testStore(t)

	_, err := s.BulkAction(store.BulkRequest{JobIDs: []string{"job_123"}, Action: "explode"})
	if err == nil {
		t.Error("expected error for unknown action")
	}
}
