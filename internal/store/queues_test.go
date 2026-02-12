package store

import (
	"encoding/json"
	"testing"
)

func TestListQueues(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "q1", Payload: json.RawMessage(`{}`)})
	s.Enqueue(EnqueueRequest{Queue: "q2", Payload: json.RawMessage(`{}`)})
	s.FlushAsync()

	queues, err := s.ListQueues()
	if err != nil {
		t.Fatalf("ListQueues() error: %v", err)
	}
	if len(queues) != 2 {
		t.Errorf("ListQueues() count = %d, want 2", len(queues))
	}
}

func TestPauseResumeQueue(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "pr.queue", Payload: json.RawMessage(`{}`)})
	s.FlushAsync()

	// Pause
	if err := s.PauseQueue("pr.queue"); err != nil {
		t.Fatalf("PauseQueue: %v", err)
	}

	// Fetch should return nil
	r, _ := s.Fetch(FetchRequest{Queues: []string{"pr.queue"}, WorkerID: "w", Hostname: "h"})
	if r != nil {
		t.Error("Fetch should return nil for paused queue")
	}

	// Resume
	if err := s.ResumeQueue("pr.queue"); err != nil {
		t.Fatalf("ResumeQueue: %v", err)
	}

	// Fetch should return job
	r, _ = s.Fetch(FetchRequest{Queues: []string{"pr.queue"}, WorkerID: "w", Hostname: "h"})
	if r == nil {
		t.Error("Fetch should return job after resume")
	}
}

func TestClearQueue(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "clear.queue", Payload: json.RawMessage(`{}`)})
	s.Enqueue(EnqueueRequest{Queue: "clear.queue", Payload: json.RawMessage(`{}`)})

	if err := s.ClearQueue("clear.queue"); err != nil {
		t.Fatalf("ClearQueue: %v", err)
	}

	var count int
	s.db.Read.QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'clear.queue'").Scan(&count)
	if count != 0 {
		t.Errorf("jobs count after clear = %d, want 0", count)
	}
}

func TestDeleteQueue(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "del.queue", Payload: json.RawMessage(`{}`)})
	s.FlushAsync()

	if err := s.DeleteQueue("del.queue"); err != nil {
		t.Fatalf("DeleteQueue: %v", err)
	}

	var count int
	s.db.Read.QueryRow("SELECT COUNT(*) FROM queues WHERE name = 'del.queue'").Scan(&count)
	if count != 0 {
		t.Error("queue should be deleted")
	}
	s.db.Read.QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'del.queue'").Scan(&count)
	if count != 0 {
		t.Error("jobs should be deleted")
	}
}

func TestSetConcurrency(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "conc.queue", Payload: json.RawMessage(`{}`)})
	s.Enqueue(EnqueueRequest{Queue: "conc.queue", Payload: json.RawMessage(`{}`)})
	s.FlushAsync()

	// Set concurrency to 1
	if err := s.SetConcurrency("conc.queue", 1); err != nil {
		t.Fatalf("SetConcurrency: %v", err)
	}

	// First fetch should work
	r1, _ := s.Fetch(FetchRequest{Queues: []string{"conc.queue"}, WorkerID: "w1", Hostname: "h"})
	if r1 == nil {
		t.Fatal("first fetch should succeed")
	}

	// Second fetch should return nil (concurrency limit)
	r2, _ := s.Fetch(FetchRequest{Queues: []string{"conc.queue"}, WorkerID: "w2", Hostname: "h"})
	if r2 != nil {
		t.Error("second fetch should return nil due to concurrency limit")
	}
}

func TestSetAndRemoveThrottle(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "throttle.queue", Payload: json.RawMessage(`{}`)})
	s.FlushAsync()

	if err := s.SetThrottle("throttle.queue", 100, 60000); err != nil {
		t.Fatalf("SetThrottle: %v", err)
	}

	var rateLimit, rateWindow int
	s.db.Read.QueryRow("SELECT rate_limit, rate_window_ms FROM queues WHERE name = 'throttle.queue'").
		Scan(&rateLimit, &rateWindow)
	if rateLimit != 100 || rateWindow != 60000 {
		t.Errorf("rate_limit=%d window=%d, want 100/60000", rateLimit, rateWindow)
	}

	if err := s.RemoveThrottle("throttle.queue"); err != nil {
		t.Fatalf("RemoveThrottle: %v", err)
	}

	var rl, rw *int
	s.db.Read.QueryRow("SELECT rate_limit, rate_window_ms FROM queues WHERE name = 'throttle.queue'").
		Scan(&rl, &rw)
	if rl != nil || rw != nil {
		t.Error("rate limit should be NULL after removal")
	}
}

func TestPauseNonexistentQueue(t *testing.T) {
	s := testStore(t)

	err := s.PauseQueue("no.such.queue")
	if err == nil {
		t.Error("PauseQueue should error for nonexistent queue")
	}
}
