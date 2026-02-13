package store_test

import (
	"encoding/json"
	"testing"

	"github.com/user/jobbie/internal/store"
)

func TestGetJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "get.queue",
		Payload: json.RawMessage(`{"key":"value"}`),
		Tags:    json.RawMessage(`{"env":"test"}`),
	})

	job, err := s.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.ID != enqResult.JobID {
		t.Errorf("job ID = %q, want %q", job.ID, enqResult.JobID)
	}
	if job.Queue != "get.queue" {
		t.Errorf("queue = %q, want %q", job.Queue, "get.queue")
	}
	if job.State != store.StatePending {
		t.Errorf("state = %q, want %q", job.State, store.StatePending)
	}
	if string(job.Payload) != `{"key":"value"}` {
		t.Errorf("payload = %s", job.Payload)
	}
	if string(job.Tags) != `{"env":"test"}` {
		t.Errorf("tags = %s", job.Tags)
	}
}

func TestGetJobWithErrors(t *testing.T) {
	s := testStore(t)

	maxRetries := 3
	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:      "err.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	s.Fetch(store.FetchRequest{Queues: []string{"err.queue"}, WorkerID: "w", Hostname: "h"})
	s.Fail(enqResult.JobID, "first error", "trace1")

	job, err := s.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if len(job.Errors) != 1 {
		t.Fatalf("errors count = %d, want 1", len(job.Errors))
	}
	if job.Errors[0].Error != "first error" {
		t.Errorf("error message = %q", job.Errors[0].Error)
	}
}

func TestGetJobNotFound(t *testing.T) {
	s := testStore(t)
	_, err := s.GetJob("nonexistent")
	if err == nil {
		t.Error("GetJob should error for nonexistent job")
	}
}

func TestRetryJob(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:      "retry.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	s.Fetch(store.FetchRequest{Queues: []string{"retry.queue"}, WorkerID: "w", Hostname: "h"})
	s.Fail(enqResult.JobID, "error", "")

	// Job should be dead
	job, _ := s.GetJob(enqResult.JobID)
	if job.State != store.StateDead {
		t.Fatalf("job state = %q, want dead", job.State)
	}

	// Retry it
	if err := s.RetryJob(enqResult.JobID); err != nil {
		t.Fatalf("RetryJob: %v", err)
	}

	job, _ = s.GetJob(enqResult.JobID)
	if job.State != store.StatePending {
		t.Errorf("job state after retry = %q, want pending", job.State)
	}
	if job.Attempt != 0 {
		t.Errorf("attempt after retry = %d, want 0", job.Attempt)
	}
}

func TestCancelPendingJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "cancel.queue",
		Payload: json.RawMessage(`{}`),
	})

	status, err := s.CancelJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("CancelJob: %v", err)
	}
	if status != store.StateCancelled {
		t.Errorf("status = %q, want %q", status, store.StateCancelled)
	}

	job, _ := s.GetJob(enqResult.JobID)
	if job.State != store.StateCancelled {
		t.Errorf("job state = %q, want cancelled", job.State)
	}
}

func TestCancelActiveJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "cancel.active",
		Payload: json.RawMessage(`{}`),
	})
	s.Fetch(store.FetchRequest{Queues: []string{"cancel.active"}, WorkerID: "w", Hostname: "h"})

	status, err := s.CancelJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("CancelJob: %v", err)
	}
	if status != "cancelling" {
		t.Errorf("status = %q, want %q", status, "cancelling")
	}
}

func TestMoveJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "source.queue",
		Payload: json.RawMessage(`{}`),
	})

	if err := s.MoveJob(enqResult.JobID, "target.queue"); err != nil {
		t.Fatalf("MoveJob: %v", err)
	}

	job, _ := s.GetJob(enqResult.JobID)
	if job.Queue != "target.queue" {
		t.Errorf("queue = %q, want %q", job.Queue, "target.queue")
	}
}

func TestDeleteJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "del.queue",
		Payload: json.RawMessage(`{}`),
	})

	if err := s.DeleteJob(enqResult.JobID); err != nil {
		t.Fatalf("DeleteJob: %v", err)
	}

	_, err := s.GetJob(enqResult.JobID)
	if err == nil {
		t.Error("GetJob should error after delete")
	}
}

func TestDeleteJobNotFound(t *testing.T) {
	s := testStore(t)
	err := s.DeleteJob("nonexistent")
	if err == nil {
		t.Error("DeleteJob should error for nonexistent job")
	}
}
