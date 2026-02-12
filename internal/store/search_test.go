package store

import (
	"encoding/json"
	"testing"

	"github.com/user/jobbie/internal/search"
)

func TestSearchJobsByQueue(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "search.q1", Payload: json.RawMessage(`{}`)})
	s.Enqueue(EnqueueRequest{Queue: "search.q1", Payload: json.RawMessage(`{}`)})
	s.Enqueue(EnqueueRequest{Queue: "search.q2", Payload: json.RawMessage(`{}`)})

	result, err := s.SearchJobs(search.Filter{Queue: "search.q1"})
	if err != nil {
		t.Fatalf("SearchJobs: %v", err)
	}
	if result.Total != 2 {
		t.Errorf("total = %d, want 2", result.Total)
	}
	if len(result.Jobs) != 2 {
		t.Errorf("jobs count = %d, want 2", len(result.Jobs))
	}
}

func TestSearchJobsByState(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	s.Enqueue(EnqueueRequest{Queue: "search.state", Payload: json.RawMessage(`{}`), MaxRetries: &maxRetries})
	s.Enqueue(EnqueueRequest{Queue: "search.state", Payload: json.RawMessage(`{}`), MaxRetries: &maxRetries})

	// Fetch and fail one to make it dead
	r, _ := s.Fetch(FetchRequest{Queues: []string{"search.state"}, WorkerID: "w", Hostname: "h"})
	s.Fail(r.JobID, "err", "")

	result, err := s.SearchJobs(search.Filter{Queue: "search.state", State: []string{"pending"}})
	if err != nil {
		t.Fatalf("SearchJobs: %v", err)
	}
	if result.Total != 1 {
		t.Errorf("pending total = %d, want 1", result.Total)
	}
}

func TestSearchJobsByPayloadContains(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "search.payload", Payload: json.RawMessage(`{"email":"alice@example.com"}`)})
	s.Enqueue(EnqueueRequest{Queue: "search.payload", Payload: json.RawMessage(`{"email":"bob@example.com"}`)})

	result, err := s.SearchJobs(search.Filter{PayloadContains: "alice"})
	if err != nil {
		t.Fatalf("SearchJobs: %v", err)
	}
	if result.Total != 1 {
		t.Errorf("total = %d, want 1", result.Total)
	}
}

func TestSearchJobsPagination(t *testing.T) {
	s := testStore(t)

	for range 5 {
		s.Enqueue(EnqueueRequest{Queue: "search.page", Payload: json.RawMessage(`{}`)})
	}

	// Page 1
	result1, _ := s.SearchJobs(search.Filter{Queue: "search.page", Limit: 2})
	if len(result1.Jobs) != 2 {
		t.Errorf("page 1 jobs = %d, want 2", len(result1.Jobs))
	}
	if result1.Total != 5 {
		t.Errorf("total = %d, want 5", result1.Total)
	}
	if !result1.HasMore {
		t.Error("should have more")
	}
	if result1.Cursor == "" {
		t.Error("cursor should not be empty")
	}

	// Page 2
	result2, _ := s.SearchJobs(search.Filter{Queue: "search.page", Limit: 2, Cursor: result1.Cursor})
	if len(result2.Jobs) != 2 {
		t.Errorf("page 2 jobs = %d, want 2", len(result2.Jobs))
	}
	if !result2.HasMore {
		t.Error("should have more")
	}

	// Page 3 (last)
	result3, _ := s.SearchJobs(search.Filter{Queue: "search.page", Limit: 2, Cursor: result2.Cursor})
	if len(result3.Jobs) != 1 {
		t.Errorf("page 3 jobs = %d, want 1", len(result3.Jobs))
	}
	if result3.HasMore {
		t.Error("should not have more")
	}
}

func TestSearchJobsByTags(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "search.tags", Payload: json.RawMessage(`{}`), Tags: json.RawMessage(`{"tenant":"acme"}`)})
	s.Enqueue(EnqueueRequest{Queue: "search.tags", Payload: json.RawMessage(`{}`), Tags: json.RawMessage(`{"tenant":"other"}`)})

	result, err := s.SearchJobs(search.Filter{Tags: map[string]string{"tenant": "acme"}})
	if err != nil {
		t.Fatalf("SearchJobs: %v", err)
	}
	if result.Total != 1 {
		t.Errorf("total = %d, want 1", result.Total)
	}
}

func TestSearchDurationMs(t *testing.T) {
	s := testStore(t)
	s.Enqueue(EnqueueRequest{Queue: "search.dur", Payload: json.RawMessage(`{}`)})

	result, _ := s.SearchJobs(search.Filter{})
	if result.DurationMs < 0 {
		t.Error("duration_ms should be >= 0")
	}
}
