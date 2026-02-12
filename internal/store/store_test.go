package store

import (
	"encoding/json"
	"testing"
	"time"
)

// testStore creates a Store with a temporary database for testing.
func testStore(t *testing.T) *Store {
	t.Helper()
	db, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	s := NewStore(db)
	t.Cleanup(func() { s.Close() })
	return s
}

func TestEnqueue(t *testing.T) {
	s := testStore(t)

	result, err := s.Enqueue(EnqueueRequest{
		Queue:   "test.queue",
		Payload: json.RawMessage(`{"hello":"world"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}
	if result.JobID == "" {
		t.Error("Enqueue() returned empty job ID")
	}
	if result.Status != StatePending {
		t.Errorf("Enqueue() status = %q, want %q", result.Status, StatePending)
	}
	if result.UniqueExisting {
		t.Error("Enqueue() returned unique_existing = true for non-unique job")
	}

	// Verify job exists in DB
	var state string
	err = s.db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", result.JobID).Scan(&state)
	if err != nil {
		t.Fatalf("query job: %v", err)
	}
	if state != StatePending {
		t.Errorf("job state = %q, want %q", state, StatePending)
	}
}

func TestEnqueueWithPriority(t *testing.T) {
	s := testStore(t)

	result, err := s.Enqueue(EnqueueRequest{
		Queue:    "test.queue",
		Payload:  json.RawMessage(`{}`),
		Priority: "critical",
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}

	var priority int
	s.db.Read.QueryRow("SELECT priority FROM jobs WHERE id = ?", result.JobID).Scan(&priority)
	if priority != PriorityCritical {
		t.Errorf("priority = %d, want %d", priority, PriorityCritical)
	}
}

func TestEnqueueScheduled(t *testing.T) {
	s := testStore(t)

	future := time.Now().Add(1 * time.Hour)
	result, err := s.Enqueue(EnqueueRequest{
		Queue:       "test.queue",
		Payload:     json.RawMessage(`{}`),
		ScheduledAt: &future,
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}
	if result.Status != StateScheduled {
		t.Errorf("status = %q, want %q", result.Status, StateScheduled)
	}
}

func TestEnqueueUniqueDuplicate(t *testing.T) {
	s := testStore(t)

	req := EnqueueRequest{
		Queue:     "test.queue",
		Payload:   json.RawMessage(`{}`),
		UniqueKey: "unique-1",
	}

	r1, err := s.Enqueue(req)
	if err != nil {
		t.Fatalf("first Enqueue() error: %v", err)
	}
	if r1.UniqueExisting {
		t.Error("first enqueue should not be duplicate")
	}

	r2, err := s.Enqueue(req)
	if err != nil {
		t.Fatalf("second Enqueue() error: %v", err)
	}
	if !r2.UniqueExisting {
		t.Error("second enqueue should be duplicate")
	}
	if r2.JobID != r1.JobID {
		t.Errorf("duplicate job ID = %q, want %q", r2.JobID, r1.JobID)
	}
	if r2.Status != "duplicate" {
		t.Errorf("duplicate status = %q, want %q", r2.Status, "duplicate")
	}
}

func TestEnqueueCreatesQueueRow(t *testing.T) {
	s := testStore(t)

	_, err := s.Enqueue(EnqueueRequest{
		Queue:   "auto.created",
		Payload: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}

	// Queue row is created asynchronously
	s.FlushAsync()

	var name string
	err = s.db.Read.QueryRow("SELECT name FROM queues WHERE name = ?", "auto.created").Scan(&name)
	if err != nil {
		t.Fatalf("queue not auto-created: %v", err)
	}
}

func TestEnqueueUpdatesQueueStats(t *testing.T) {
	s := testStore(t)

	for range 3 {
		_, err := s.Enqueue(EnqueueRequest{
			Queue:   "stats.queue",
			Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			t.Fatalf("Enqueue() error: %v", err)
		}
	}

	// Flush async writer so stats are visible on the read connection
	s.FlushAsync()

	var enqueued int
	s.db.Read.QueryRow("SELECT enqueued FROM queue_stats WHERE queue = ?", "stats.queue").Scan(&enqueued)
	if enqueued != 3 {
		t.Errorf("enqueued = %d, want 3", enqueued)
	}
}

func TestFetchBasic(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{
		Queue:   "test.queue",
		Payload: json.RawMessage(`{"task":"do-it"}`),
	})

	fetchResult, err := s.Fetch(FetchRequest{
		Queues:   []string{"test.queue"},
		WorkerID: "worker-1",
		Hostname: "host-1",
	})
	if err != nil {
		t.Fatalf("Fetch() error: %v", err)
	}
	if fetchResult == nil {
		t.Fatal("Fetch() returned nil")
	}
	if fetchResult.JobID != enqResult.JobID {
		t.Errorf("Fetch() job ID = %q, want %q", fetchResult.JobID, enqResult.JobID)
	}
	if fetchResult.Queue != "test.queue" {
		t.Errorf("Fetch() queue = %q, want %q", fetchResult.Queue, "test.queue")
	}
	if fetchResult.Attempt != 1 {
		t.Errorf("Fetch() attempt = %d, want 1", fetchResult.Attempt)
	}

	// Verify job is now active
	var state string
	s.db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", enqResult.JobID).Scan(&state)
	if state != StateActive {
		t.Errorf("job state = %q, want %q", state, StateActive)
	}
}

func TestFetchReturnsNilWhenEmpty(t *testing.T) {
	s := testStore(t)

	fetchResult, err := s.Fetch(FetchRequest{
		Queues:   []string{"empty.queue"},
		WorkerID: "worker-1",
		Hostname: "host-1",
	})
	if err != nil {
		t.Fatalf("Fetch() error: %v", err)
	}
	if fetchResult != nil {
		t.Errorf("Fetch() should return nil for empty queue, got %+v", fetchResult)
	}
}

func TestFetchPriorityOrder(t *testing.T) {
	s := testStore(t)

	// Enqueue normal, then critical
	s.Enqueue(EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"normal"}`), Priority: "normal"})
	s.Enqueue(EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"critical"}`), Priority: "critical"})

	// Fetch should return critical first
	r, _ := s.Fetch(FetchRequest{Queues: []string{"prio.queue"}, WorkerID: "w", Hostname: "h"})
	if r == nil {
		t.Fatal("Fetch() returned nil")
	}
	if string(r.Payload) != `{"p":"critical"}` {
		t.Errorf("Fetch() payload = %s, want critical job first", r.Payload)
	}
}

func TestFetchSkipsPausedQueue(t *testing.T) {
	s := testStore(t)

	s.Enqueue(EnqueueRequest{Queue: "paused.queue", Payload: json.RawMessage(`{}`)})
	s.FlushAsync() // ensure queue row exists before pausing
	s.db.Write.Exec("UPDATE queues SET paused = 1 WHERE name = 'paused.queue'")

	r, err := s.Fetch(FetchRequest{Queues: []string{"paused.queue"}, WorkerID: "w", Hostname: "h"})
	if err != nil {
		t.Fatalf("Fetch() error: %v", err)
	}
	if r != nil {
		t.Error("Fetch() should return nil for paused queue")
	}
}

func TestAck(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{Queue: "ack.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(FetchRequest{Queues: []string{"ack.queue"}, WorkerID: "w", Hostname: "h"})

	err := s.Ack(enqResult.JobID, json.RawMessage(`{"done":true}`))
	if err != nil {
		t.Fatalf("Ack() error: %v", err)
	}

	var state string
	s.db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", enqResult.JobID).Scan(&state)
	if state != StateCompleted {
		t.Errorf("job state = %q, want %q", state, StateCompleted)
	}
}

func TestAckCleansUniquelock(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{
		Queue:     "unique.queue",
		Payload:   json.RawMessage(`{}`),
		UniqueKey: "key-1",
	})
	s.Fetch(FetchRequest{Queues: []string{"unique.queue"}, WorkerID: "w", Hostname: "h"})
	s.Ack(enqResult.JobID, nil)

	// Should be able to enqueue same unique key again
	r2, _ := s.Enqueue(EnqueueRequest{
		Queue:     "unique.queue",
		Payload:   json.RawMessage(`{}`),
		UniqueKey: "key-1",
	})
	if r2.UniqueExisting {
		t.Error("unique lock should have been cleaned after ack")
	}
}

func TestFailWithRetry(t *testing.T) {
	s := testStore(t)

	maxRetries := 3
	enqResult, _ := s.Enqueue(EnqueueRequest{
		Queue:      "fail.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	s.Fetch(FetchRequest{Queues: []string{"fail.queue"}, WorkerID: "w", Hostname: "h"})

	result, err := s.Fail(enqResult.JobID, "something broke", "stack trace here")
	if err != nil {
		t.Fatalf("Fail() error: %v", err)
	}
	if result.Status != StateRetrying {
		t.Errorf("Fail() status = %q, want %q", result.Status, StateRetrying)
	}
	if result.AttemptsRemaining != 2 {
		t.Errorf("Fail() remaining = %d, want 2", result.AttemptsRemaining)
	}
	if result.NextAttemptAt == nil {
		t.Error("Fail() next_attempt_at should not be nil for retrying")
	}

	// Verify error record was created
	var errCount int
	s.db.Read.QueryRow("SELECT COUNT(*) FROM job_errors WHERE job_id = ?", enqResult.JobID).Scan(&errCount)
	if errCount != 1 {
		t.Errorf("job_errors count = %d, want 1", errCount)
	}
}

func TestFailDead(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	enqResult, _ := s.Enqueue(EnqueueRequest{
		Queue:      "dead.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	s.Fetch(FetchRequest{Queues: []string{"dead.queue"}, WorkerID: "w", Hostname: "h"})

	result, err := s.Fail(enqResult.JobID, "fatal error", "")
	if err != nil {
		t.Fatalf("Fail() error: %v", err)
	}
	if result.Status != StateDead {
		t.Errorf("Fail() status = %q, want %q", result.Status, StateDead)
	}
	if result.AttemptsRemaining != 0 {
		t.Errorf("Fail() remaining = %d, want 0", result.AttemptsRemaining)
	}
}

func TestHeartbeatExtendsLease(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{Queue: "hb.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(FetchRequest{Queues: []string{"hb.queue"}, WorkerID: "w", Hostname: "h"})

	// Get current lease
	var leaseBefore string
	s.db.Read.QueryRow("SELECT lease_expires_at FROM jobs WHERE id = ?", enqResult.JobID).Scan(&leaseBefore)

	time.Sleep(10 * time.Millisecond) // ensure time moves forward

	resp, err := s.Heartbeat(HeartbeatRequest{
		Jobs: map[string]HeartbeatJobUpdate{
			enqResult.JobID: {},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat() error: %v", err)
	}
	if resp.Jobs[enqResult.JobID].Status != "ok" {
		t.Errorf("Heartbeat() status = %q, want %q", resp.Jobs[enqResult.JobID].Status, "ok")
	}

	var leaseAfter string
	s.db.Read.QueryRow("SELECT lease_expires_at FROM jobs WHERE id = ?", enqResult.JobID).Scan(&leaseAfter)
	if leaseAfter <= leaseBefore {
		t.Error("Heartbeat() should have extended the lease")
	}
}

func TestHeartbeatWithProgress(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{Queue: "prog.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(FetchRequest{Queues: []string{"prog.queue"}, WorkerID: "w", Hostname: "h"})

	_, err := s.Heartbeat(HeartbeatRequest{
		Jobs: map[string]HeartbeatJobUpdate{
			enqResult.JobID: {
				Progress: map[string]interface{}{
					"current": 50,
					"total":   100,
					"message": "processing",
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat() error: %v", err)
	}

	var progress string
	s.db.Read.QueryRow("SELECT progress FROM jobs WHERE id = ?", enqResult.JobID).Scan(&progress)
	if progress == "" {
		t.Error("progress should have been set")
	}
}

func TestHeartbeatWithCheckpoint(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{Queue: "cp.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(FetchRequest{Queues: []string{"cp.queue"}, WorkerID: "w", Hostname: "h"})

	_, err := s.Heartbeat(HeartbeatRequest{
		Jobs: map[string]HeartbeatJobUpdate{
			enqResult.JobID: {
				Checkpoint: map[string]interface{}{
					"offset": 42000,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat() error: %v", err)
	}

	var checkpoint string
	s.db.Read.QueryRow("SELECT checkpoint FROM jobs WHERE id = ?", enqResult.JobID).Scan(&checkpoint)
	if checkpoint == "" {
		t.Error("checkpoint should have been set")
	}
}

func TestHeartbeatCancelledJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(EnqueueRequest{Queue: "cancel.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(FetchRequest{Queues: []string{"cancel.queue"}, WorkerID: "w", Hostname: "h"})

	// Manually cancel the job
	s.db.Write.Exec("UPDATE jobs SET state = 'cancelled' WHERE id = ?", enqResult.JobID)

	resp, err := s.Heartbeat(HeartbeatRequest{
		Jobs: map[string]HeartbeatJobUpdate{
			enqResult.JobID: {},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat() error: %v", err)
	}
	if resp.Jobs[enqResult.JobID].Status != "cancel" {
		t.Errorf("Heartbeat() status = %q, want %q", resp.Jobs[enqResult.JobID].Status, "cancel")
	}
}

func TestBackoffCalculation(t *testing.T) {
	tests := []struct {
		strategy string
		attempt  int
		baseMs   int
		maxMs    int
		expected time.Duration
	}{
		{BackoffNone, 1, 5000, 600000, 0},
		{BackoffFixed, 1, 5000, 600000, 5 * time.Second},
		{BackoffFixed, 3, 5000, 600000, 5 * time.Second},
		{BackoffLinear, 1, 5000, 600000, 5 * time.Second},
		{BackoffLinear, 3, 5000, 600000, 15 * time.Second},
		{BackoffExponential, 1, 5000, 600000, 5 * time.Second},
		{BackoffExponential, 2, 5000, 600000, 10 * time.Second},
		{BackoffExponential, 3, 5000, 600000, 20 * time.Second},
		{BackoffExponential, 10, 5000, 600000, 600 * time.Second}, // capped at max
	}

	for _, tt := range tests {
		got := CalculateBackoff(tt.strategy, tt.attempt, tt.baseMs, tt.maxMs)
		if got != tt.expected {
			t.Errorf("CalculateBackoff(%s, %d, %d, %d) = %v, want %v",
				tt.strategy, tt.attempt, tt.baseMs, tt.maxMs, got, tt.expected)
		}
	}
}

func TestEnqueueBatch(t *testing.T) {
	s := testStore(t)

	result, err := s.EnqueueBatch(BatchEnqueueRequest{
		Jobs: []EnqueueRequest{
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":1}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":2}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":3}`)},
		},
		Batch: &BatchConfig{
			CallbackQueue:   "batch.callback",
			CallbackPayload: json.RawMessage(`{"campaign":"test"}`),
		},
	})
	if err != nil {
		t.Fatalf("EnqueueBatch() error: %v", err)
	}
	if len(result.JobIDs) != 3 {
		t.Errorf("EnqueueBatch() job count = %d, want 3", len(result.JobIDs))
	}
	if result.BatchID == "" {
		t.Error("EnqueueBatch() batch ID should not be empty")
	}

	// Verify batch row
	var total, pending int
	s.db.Read.QueryRow("SELECT total, pending FROM batches WHERE id = ?", result.BatchID).Scan(&total, &pending)
	if total != 3 || pending != 3 {
		t.Errorf("batch total=%d pending=%d, want 3/3", total, pending)
	}
}

func TestBatchCompletionCallback(t *testing.T) {
	s := testStore(t)

	_, _ = s.EnqueueBatch(BatchEnqueueRequest{
		Jobs: []EnqueueRequest{
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":1}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":2}`)},
		},
		Batch: &BatchConfig{
			CallbackQueue:   "batch.done",
			CallbackPayload: json.RawMessage(`{"done":true}`),
		},
	})

	// Fetch and ack both jobs
	for range 2 {
		r, _ := s.Fetch(FetchRequest{Queues: []string{"batch.queue"}, WorkerID: "w", Hostname: "h"})
		if r == nil {
			t.Fatal("Fetch() returned nil")
		}
		s.Ack(r.JobID, nil)
	}

	// Verify callback job was enqueued
	var count int
	s.db.Read.QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'batch.done'").Scan(&count)
	if count != 1 {
		t.Errorf("callback job count = %d, want 1", count)
	}
}

func TestFullJobLifecycle(t *testing.T) {
	s := testStore(t)

	// 1. Enqueue
	enqResult, err := s.Enqueue(EnqueueRequest{
		Queue:   "lifecycle.queue",
		Payload: json.RawMessage(`{"step":"lifecycle"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// 2. Fetch
	fetchResult, err := s.Fetch(FetchRequest{
		Queues: []string{"lifecycle.queue"}, WorkerID: "w1", Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if fetchResult.JobID != enqResult.JobID {
		t.Fatalf("Fetch returned wrong job")
	}

	// 3. Ack
	err = s.Ack(enqResult.JobID, json.RawMessage(`{"result":"success"}`))
	if err != nil {
		t.Fatalf("Ack: %v", err)
	}

	// 4. Verify completed
	var state string
	s.db.Read.QueryRow("SELECT state FROM jobs WHERE id = ?", enqResult.JobID).Scan(&state)
	if state != StateCompleted {
		t.Errorf("final state = %q, want %q", state, StateCompleted)
	}
}
