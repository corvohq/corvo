package scheduler

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/user/jobbie/internal/store"
)

func testSetup(t *testing.T) (*store.Store, *Scheduler, *store.DB) {
	t.Helper()
	db, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	s := store.NewStore(db)
	t.Cleanup(func() { s.Close() })
	sched := New(db.Write, DefaultConfig())
	return s, sched, db
}

func TestPromoteScheduledJobs(t *testing.T) {
	s, sched, db := testSetup(t)

	// Enqueue a job scheduled in the past
	past := time.Now().Add(-1 * time.Second)
	result, err := s.Enqueue(store.EnqueueRequest{
		Queue:       "sched.queue",
		Payload:     json.RawMessage(`{}`),
		ScheduledAt: &past,
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Verify it's scheduled
	var state string
	db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "scheduled" {
		t.Fatalf("job state = %q, want 'scheduled'", state)
	}

	// Run scheduler
	sched.RunOnce()

	// Verify it's now pending
	db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "pending" {
		t.Errorf("job state after promote = %q, want 'pending'", state)
	}
}

func TestPromoteRetryingJobs(t *testing.T) {
	s, sched, db := testSetup(t)

	maxRetries := 3
	result, _ := s.Enqueue(store.EnqueueRequest{
		Queue:          "retry.queue",
		Payload:        json.RawMessage(`{}`),
		MaxRetries:     &maxRetries,
		RetryBackoff:   "none",
	})
	s.Fetch(store.FetchRequest{Queues: []string{"retry.queue"}, WorkerID: "w", Hostname: "h"})
	s.Fail(result.JobID, "err", "")

	// With backoff=none, scheduled_at should be ~now
	// Run scheduler to promote
	sched.RunOnce()

	var state string
	db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "pending" {
		t.Errorf("job state after promote = %q, want 'pending'", state)
	}
}

func TestReclaimExpiredLeases(t *testing.T) {
	s, sched, db := testSetup(t)

	result, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "lease.queue",
		Payload: json.RawMessage(`{}`),
	})
	s.Fetch(store.FetchRequest{
		Queues:        []string{"lease.queue"},
		WorkerID:      "w",
		Hostname:      "h",
		LeaseDuration: 1, // 1 second lease
	})

	// Set lease to expired
	db.Write.Exec("UPDATE jobs SET lease_expires_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', '-10 seconds') WHERE id = ?", result.JobID)

	sched.RunOnce()

	var state string
	db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "pending" {
		t.Errorf("job state after reclaim = %q, want 'pending'", state)
	}
}

func TestCleanExpiredUniqueLocks(t *testing.T) {
	_, sched, db := testSetup(t)

	// Insert an expired unique lock
	db.Write.Exec(
		"INSERT INTO unique_locks (queue, unique_key, job_id, expires_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f', 'now', '-10 seconds'))",
		"q", "k", "j",
	)

	var count int
	db.Read.QueryRow("SELECT COUNT(*) FROM unique_locks").Scan(&count)
	if count != 1 {
		t.Fatalf("unique_locks count = %d, want 1", count)
	}

	sched.RunOnce()

	db.Read.QueryRow("SELECT COUNT(*) FROM unique_locks").Scan(&count)
	if count != 0 {
		t.Errorf("unique_locks count after cleanup = %d, want 0", count)
	}
}

func TestCleanOldEvents(t *testing.T) {
	_, sched, db := testSetup(t)
	sched.config.EventRetention = 1 * time.Second

	// Insert an old event
	db.Write.Exec(
		"INSERT INTO events (type, created_at) VALUES ('test', strftime('%Y-%m-%dT%H:%M:%f', 'now', '-10 seconds'))",
	)

	var count int
	db.Read.QueryRow("SELECT COUNT(*) FROM events").Scan(&count)
	if count != 1 {
		t.Fatalf("events count = %d, want 1", count)
	}

	sched.RunOnce()

	db.Read.QueryRow("SELECT COUNT(*) FROM events").Scan(&count)
	if count != 0 {
		t.Errorf("events count after cleanup = %d, want 0", count)
	}
}

func TestSchedulerGracefulStop(t *testing.T) {
	_, _, db := testSetup(t)
	sched := New(db.Write, Config{Interval: 50 * time.Millisecond})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		sched.Run(ctx)
		close(done)
	}()

	// Let it run a few ticks
	time.Sleep(150 * time.Millisecond)
	cancel()

	select {
	case <-done:
		// good, stopped
	case <-time.After(1 * time.Second):
		t.Error("scheduler did not stop within timeout")
	}
}
