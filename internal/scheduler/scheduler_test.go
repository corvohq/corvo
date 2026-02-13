package scheduler

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"
	"time"

	"github.com/user/jobbie/internal/raft"
	"github.com/user/jobbie/internal/store"
)

func testSetup(t *testing.T) (*store.Store, *Scheduler, *sql.DB) {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { s.Close() })
	sched := New(s, nil, DefaultConfig())
	return s, sched, da.SQLiteDB()
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
	db.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "scheduled" {
		t.Fatalf("job state = %q, want 'scheduled'", state)
	}

	// Run scheduler
	sched.RunOnce()

	// Verify it's now pending
	db.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "pending" {
		t.Errorf("job state after promote = %q, want 'pending'", state)
	}
}

func TestPromoteRetryingJobs(t *testing.T) {
	s, sched, db := testSetup(t)

	maxRetries := 3
	result, _ := s.Enqueue(store.EnqueueRequest{
		Queue:        "retry.queue",
		Payload:      json.RawMessage(`{}`),
		MaxRetries:   &maxRetries,
		RetryBackoff: "none",
	})
	s.Fetch(store.FetchRequest{Queues: []string{"retry.queue"}, WorkerID: "w", Hostname: "h"})
	s.Fail(result.JobID, "err", "", false)

	// With backoff=none, scheduled_at should be ~now
	// Run scheduler to promote
	sched.RunOnce()

	var state string
	db.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
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

	// Wait for lease to expire.
	time.Sleep(1100 * time.Millisecond)

	sched.RunOnce()

	var state string
	db.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if state != "pending" {
		t.Errorf("job state after reclaim = %q, want 'pending'", state)
	}
}

func TestCleanExpiredUniqueLocks(t *testing.T) {
	_, sched, db := testSetup(t)

	// Insert an expired unique lock
	db.Exec(
		"INSERT INTO unique_locks (queue, unique_key, job_id, expires_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f', 'now', '-10 seconds'))",
		"q", "k", "j",
	)

	var count int
	db.QueryRow("SELECT COUNT(*) FROM unique_locks").Scan(&count)
	if count != 1 {
		t.Fatalf("unique_locks count = %d, want 1", count)
	}

	sched.RunOnce()

	db.QueryRow("SELECT COUNT(*) FROM unique_locks").Scan(&count)
	if count != 0 {
		t.Errorf("unique_locks count after cleanup = %d, want 0", count)
	}
}

func TestSchedulerGracefulStop(t *testing.T) {
	s, _, _ := testSetup(t)
	sched := New(s, nil, Config{Interval: 50 * time.Millisecond})

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
