package store_test

import (
	"encoding/json"
	"strconv"
	"testing"
	"time"

	"github.com/corvohq/corvo/internal/raft"
	"github.com/corvohq/corvo/internal/store"
)

// testStore creates a Store backed by a DirectApplier for testing.
func testStore(t *testing.T) *store.Store {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { _ = da.Close() })
	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// testStoreAsync creates a Store with async SQLite mirror enabled,
// matching the production default where SQLite writes are batched.
func testStoreAsync(t *testing.T) *store.Store {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	da.SetSQLiteMirrorAsync(true)
	t.Cleanup(func() { _ = da.Close() })
	return store.NewStore(da, da.SQLiteDB())
}

func TestEnqueue(t *testing.T) {
	s := testStore(t)

	result, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "test.queue",
		Payload: json.RawMessage(`{"hello":"world"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}
	if result.JobID == "" {
		t.Error("Enqueue() returned empty job ID")
	}
	if result.Status != store.StatePending {
		t.Errorf("Enqueue() status = %q, want %q", result.Status, store.StatePending)
	}
	if result.UniqueExisting {
		t.Error("Enqueue() returned unique_existing = true for non-unique job")
	}

	// Verify via GetJob
	job, err := s.GetJob(result.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.State != store.StatePending {
		t.Errorf("job state = %q, want %q", job.State, store.StatePending)
	}
}

func TestEnqueueWithPriority(t *testing.T) {
	s := testStore(t)

	result, err := s.Enqueue(store.EnqueueRequest{
		Queue:    "test.queue",
		Payload:  json.RawMessage(`{}`),
		Priority: "critical",
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}

	job, _ := s.GetJob(result.JobID)
	if job.Priority != store.PriorityCritical {
		t.Errorf("priority = %d, want %d", job.Priority, store.PriorityCritical)
	}
}

func TestEnqueueScheduled(t *testing.T) {
	s := testStore(t)

	future := time.Now().Add(1 * time.Hour)
	result, err := s.Enqueue(store.EnqueueRequest{
		Queue:       "test.queue",
		Payload:     json.RawMessage(`{}`),
		ScheduledAt: &future,
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}
	if result.Status != store.StateScheduled {
		t.Errorf("status = %q, want %q", result.Status, store.StateScheduled)
	}
}

func TestEnqueueUniqueDuplicate(t *testing.T) {
	s := testStore(t)

	req := store.EnqueueRequest{
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

func TestEnqueueQueueAppearsInList(t *testing.T) {
	s := testStore(t)

	_, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "auto.created",
		Payload: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("Enqueue() error: %v", err)
	}

	queues, err := s.ListQueues()
	if err != nil {
		t.Fatalf("ListQueues() error: %v", err)
	}
	found := false
	for _, q := range queues {
		if q.Name == "auto.created" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("queue 'auto.created' not found in ListQueues")
	}
}

func TestFetchBasic(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "test.queue",
		Payload: json.RawMessage(`{"task":"do-it"}`),
	})

	fetchResult, err := s.Fetch(store.FetchRequest{
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
	job, _ := s.GetJob(enqResult.JobID)
	if job.State != store.StateActive {
		t.Errorf("job state = %q, want %q", job.State, store.StateActive)
	}
}

func TestFetchReturnsNilWhenEmpty(t *testing.T) {
	s := testStore(t)

	fetchResult, err := s.Fetch(store.FetchRequest{
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

	_, _ = s.Enqueue(store.EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"normal"}`), Priority: "normal"})
	_, _ = s.Enqueue(store.EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"critical"}`), Priority: "critical"})

	r, _ := s.Fetch(store.FetchRequest{Queues: []string{"prio.queue"}, WorkerID: "w", Hostname: "h"})
	if r == nil {
		t.Fatal("Fetch() returned nil")
	}
	if string(r.Payload) != `{"p":"critical"}` {
		t.Errorf("Fetch() payload = %s, want critical job first", r.Payload)
	}
}

func TestFetchSkipsPausedQueue(t *testing.T) {
	s := testStore(t)

	_, _ = s.Enqueue(store.EnqueueRequest{Queue: "paused.queue", Payload: json.RawMessage(`{}`)})
	_ = s.PauseQueue("paused.queue")

	r, err := s.Fetch(store.FetchRequest{Queues: []string{"paused.queue"}, WorkerID: "w", Hostname: "h"})
	if err != nil {
		t.Fatalf("Fetch() error: %v", err)
	}
	if r != nil {
		t.Error("Fetch() should return nil for paused queue")
	}
}

func TestAck(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "ack.queue", Payload: json.RawMessage(`{}`)})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"ack.queue"}, WorkerID: "w", Hostname: "h"})

	err := s.Ack(enqResult.JobID, json.RawMessage(`{"done":true}`))
	if err != nil {
		t.Fatalf("Ack() error: %v", err)
	}

	job, _ := s.GetJob(enqResult.JobID)
	if job.State != store.StateCompleted {
		t.Errorf("job state = %q, want %q", job.State, store.StateCompleted)
	}
}

func TestAckCleansUniqueLock(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:     "unique.queue",
		Payload:   json.RawMessage(`{}`),
		UniqueKey: "key-1",
	})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"unique.queue"}, WorkerID: "w", Hostname: "h"})
	_ = s.Ack(enqResult.JobID, nil)

	// Should be able to enqueue same unique key again
	r2, _ := s.Enqueue(store.EnqueueRequest{
		Queue:     "unique.queue",
		Payload:   json.RawMessage(`{}`),
		UniqueKey: "key-1",
	})
	if r2.UniqueExisting {
		t.Error("unique lock should have been cleaned after ack")
	}
}

func TestAgentContinueTransitionsAndGuardrailHold(t *testing.T) {
	s := testStore(t)

	enq, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "agent.loop",
		Payload: json.RawMessage(`{"task":"iterate"}`),
		Agent: &store.AgentConfig{
			MaxIterations: 2,
			MaxCostUSD:    1.0,
		},
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	f1, err := s.Fetch(store.FetchRequest{Queues: []string{"agent.loop"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #1: %v", err)
	}
	if f1 == nil {
		t.Fatal("Fetch #1 returned nil")
	}
	if f1.Agent == nil || f1.Agent.Iteration != 1 {
		t.Fatalf("fetch #1 agent iteration = %+v, want iteration=1", f1.Agent)
	}

	err = s.AckJob(store.AckRequest{
		JobID:       f1.JobID,
		AgentStatus: store.AgentStatusContinue,
		Checkpoint:  json.RawMessage(`{"step":1}`),
		Usage:       &store.UsageReport{CostUSD: 0.2},
	})
	if err != nil {
		t.Fatalf("Ack continue #1: %v", err)
	}

	j1, err := s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("GetJob #1: %v", err)
	}
	if j1.State != store.StatePending {
		t.Fatalf("state after continue #1 = %s, want %s", j1.State, store.StatePending)
	}
	if j1.Agent == nil || j1.Agent.Iteration != 2 {
		t.Fatalf("agent after continue #1 = %+v, want iteration=2", j1.Agent)
	}
	if string(j1.Checkpoint) != `{"step":1}` {
		t.Fatalf("checkpoint after continue #1 = %s", string(j1.Checkpoint))
	}

	f2, err := s.Fetch(store.FetchRequest{Queues: []string{"agent.loop"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #2: %v", err)
	}
	if f2 == nil {
		t.Fatal("Fetch #2 returned nil")
	}
	if f2.Agent == nil || f2.Agent.Iteration != 2 {
		t.Fatalf("fetch #2 agent iteration = %+v, want iteration=2", f2.Agent)
	}

	err = s.AckJob(store.AckRequest{
		JobID:       f2.JobID,
		AgentStatus: store.AgentStatusContinue,
		Checkpoint:  json.RawMessage(`{"step":2}`),
		Usage:       &store.UsageReport{CostUSD: 0.3},
	})
	if err != nil {
		t.Fatalf("Ack continue #2: %v", err)
	}

	j2, err := s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("GetJob #2: %v", err)
	}
	if j2.State != store.StateHeld {
		t.Fatalf("state after continue #2 = %s, want %s", j2.State, store.StateHeld)
	}
	if j2.HoldReason == nil || *j2.HoldReason == "" {
		t.Fatalf("hold reason not set: %+v", j2.HoldReason)
	}
}

func TestReplayFromIteration(t *testing.T) {
	s := testStore(t)

	enq, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "agent.replay",
		Payload: json.RawMessage(`{"task":"replay"}`),
		Tags:    json.RawMessage(`{"tenant":"acme"}`),
		Agent: &store.AgentConfig{
			MaxIterations: 5,
			MaxCostUSD:    10,
		},
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	f1, err := s.Fetch(store.FetchRequest{Queues: []string{"agent.replay"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #1: %v", err)
	}
	if f1 == nil {
		t.Fatal("Fetch #1 returned nil")
	}
	if err := s.AckJob(store.AckRequest{
		JobID:       f1.JobID,
		AgentStatus: store.AgentStatusContinue,
		Checkpoint:  json.RawMessage(`{"cursor":"iter1"}`),
	}); err != nil {
		t.Fatalf("Ack continue: %v", err)
	}

	f2, err := s.Fetch(store.FetchRequest{Queues: []string{"agent.replay"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #2: %v", err)
	}
	if f2 == nil {
		t.Fatal("Fetch #2 returned nil")
	}
	if err := s.AckJob(store.AckRequest{
		JobID:       f2.JobID,
		AgentStatus: store.AgentStatusDone,
		Result:      json.RawMessage(`{"ok":true}`),
	}); err != nil {
		t.Fatalf("Ack done: %v", err)
	}

	replayed, err := s.ReplayFromIteration(enq.JobID, 1)
	if err != nil {
		t.Fatalf("ReplayFromIteration: %v", err)
	}
	if replayed.JobID == "" {
		t.Fatal("replay job_id is empty")
	}
	if replayed.JobID == enq.JobID {
		t.Fatal("replay reused original job ID")
	}

	j, err := s.GetJob(replayed.JobID)
	if err != nil {
		t.Fatalf("Get replayed job: %v", err)
	}
	if j.State != store.StatePending {
		t.Fatalf("replayed state = %s, want %s", j.State, store.StatePending)
	}
	if string(j.Checkpoint) != `{"cursor":"iter1"}` {
		t.Fatalf("replayed checkpoint = %s", string(j.Checkpoint))
	}
	if j.Agent == nil || j.Agent.Iteration != 1 {
		t.Fatalf("replayed agent = %+v, want iteration=1", j.Agent)
	}
}

func TestFailWithRetry(t *testing.T) {
	s := testStore(t)

	maxRetries := 3
	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:      "fail.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"fail.queue"}, WorkerID: "w", Hostname: "h"})

	result, err := s.Fail(enqResult.JobID, "something broke", "stack trace here", false)
	if err != nil {
		t.Fatalf("Fail() error: %v", err)
	}
	if result.Status != store.StateRetrying {
		t.Errorf("Fail() status = %q, want %q", result.Status, store.StateRetrying)
	}
	if result.AttemptsRemaining != 2 {
		t.Errorf("Fail() remaining = %d, want 2", result.AttemptsRemaining)
	}
	if result.NextAttemptAt == nil {
		t.Error("Fail() next_attempt_at should not be nil for retrying")
	}

	// Verify error record was created
	job, _ := s.GetJob(enqResult.JobID)
	if len(job.Errors) != 1 {
		t.Errorf("job_errors count = %d, want 1", len(job.Errors))
	}
}

func TestFailDead(t *testing.T) {
	s := testStore(t)

	maxRetries := 1
	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:      "dead.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
	})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"dead.queue"}, WorkerID: "w", Hostname: "h"})

	result, err := s.Fail(enqResult.JobID, "fatal error", "", false)
	if err != nil {
		t.Fatalf("Fail() error: %v", err)
	}
	if result.Status != store.StateDead {
		t.Errorf("Fail() status = %q, want %q", result.Status, store.StateDead)
	}
	if result.AttemptsRemaining != 0 {
		t.Errorf("Fail() remaining = %d, want 0", result.AttemptsRemaining)
	}
}


func TestHeartbeatExtendsLease(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "hb.queue", Payload: json.RawMessage(`{}`)})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"hb.queue"}, WorkerID: "w", Hostname: "h"})

	// Get current lease
	job1, _ := s.GetJob(enqResult.JobID)
	leaseBefore := job1.LeaseExpiresAt

	time.Sleep(10 * time.Millisecond) // ensure time moves forward

	resp, err := s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
			enqResult.JobID: {},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat() error: %v", err)
	}
	if resp.Jobs[enqResult.JobID].Status != "ok" {
		t.Errorf("Heartbeat() status = %q, want %q", resp.Jobs[enqResult.JobID].Status, "ok")
	}

	job2, _ := s.GetJob(enqResult.JobID)
	leaseAfter := job2.LeaseExpiresAt
	if leaseBefore != nil && leaseAfter != nil && !leaseAfter.After(*leaseBefore) {
		t.Error("Heartbeat() should have extended the lease")
	}
}

func TestHeartbeatWithProgress(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "prog.queue", Payload: json.RawMessage(`{}`)})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"prog.queue"}, WorkerID: "w", Hostname: "h"})

	_, err := s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
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

	job, _ := s.GetJob(enqResult.JobID)
	if len(job.Progress) == 0 {
		t.Error("progress should have been set")
	}
}

func TestHeartbeatWithCheckpoint(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "cp.queue", Payload: json.RawMessage(`{}`)})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"cp.queue"}, WorkerID: "w", Hostname: "h"})

	_, err := s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
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

	job, _ := s.GetJob(enqResult.JobID)
	if len(job.Checkpoint) == 0 {
		t.Error("checkpoint should have been set")
	}
}

func TestHeartbeatCancelledJob(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "cancel.queue", Payload: json.RawMessage(`{}`)})
	_, _ = s.Fetch(store.FetchRequest{Queues: []string{"cancel.queue"}, WorkerID: "w", Hostname: "h"})

	// Cancel the job via the proper API
	_, _ = s.CancelJob(enqResult.JobID)

	resp, err := s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
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
		{store.BackoffNone, 1, 5000, 600000, 0},
		{store.BackoffFixed, 1, 5000, 600000, 5 * time.Second},
		{store.BackoffFixed, 3, 5000, 600000, 5 * time.Second},
		{store.BackoffLinear, 1, 5000, 600000, 5 * time.Second},
		{store.BackoffLinear, 3, 5000, 600000, 15 * time.Second},
		{store.BackoffExponential, 1, 5000, 600000, 5 * time.Second},
		{store.BackoffExponential, 2, 5000, 600000, 10 * time.Second},
		{store.BackoffExponential, 3, 5000, 600000, 20 * time.Second},
		{store.BackoffExponential, 10, 5000, 600000, 600 * time.Second},
	}

	for _, tt := range tests {
		got := store.CalculateBackoff(tt.strategy, tt.attempt, tt.baseMs, tt.maxMs)
		if got != tt.expected {
			t.Errorf("CalculateBackoff(%s, %d, %d, %d) = %v, want %v",
				tt.strategy, tt.attempt, tt.baseMs, tt.maxMs, got, tt.expected)
		}
	}
}

func TestEnqueueBatch(t *testing.T) {
	s := testStore(t)

	result, err := s.EnqueueBatch(store.BatchEnqueueRequest{
		Jobs: []store.EnqueueRequest{
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":1}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":2}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":3}`)},
		},
		Batch: &store.BatchConfig{
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

	// Verify batch row via SQLite
	var total, pending int
	_ = s.ReadDB().QueryRow("SELECT total, pending FROM batches WHERE id = ?", result.BatchID).Scan(&total, &pending)
	if total != 3 || pending != 3 {
		t.Errorf("batch total=%d pending=%d, want 3/3", total, pending)
	}
}

func TestBatchCompletionCallback(t *testing.T) {
	s := testStore(t)

	_, _ = s.EnqueueBatch(store.BatchEnqueueRequest{
		Jobs: []store.EnqueueRequest{
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":1}`)},
			{Queue: "batch.queue", Payload: json.RawMessage(`{"i":2}`)},
		},
		Batch: &store.BatchConfig{
			CallbackQueue:   "batch.done",
			CallbackPayload: json.RawMessage(`{"done":true}`),
		},
	})

	// Fetch and ack both jobs
	for range 2 {
		r, _ := s.Fetch(store.FetchRequest{Queues: []string{"batch.queue"}, WorkerID: "w", Hostname: "h"})
		if r == nil {
			t.Fatal("Fetch() returned nil")
		}
		_ = s.Ack(r.JobID, nil)
	}

	// Verify callback job was enqueued
	var count int
	_ = s.ReadDB().QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'batch.done'").Scan(&count)
	if count != 1 {
		t.Errorf("callback job count = %d, want 1", count)
	}
}

func TestFullJobLifecycle(t *testing.T) {
	s := testStore(t)

	// 1. Enqueue
	enqResult, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "lifecycle.queue",
		Payload: json.RawMessage(`{"step":"lifecycle"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// 2. Fetch
	fetchResult, err := s.Fetch(store.FetchRequest{
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
	job, _ := s.GetJob(enqResult.JobID)
	if job.State != store.StateCompleted {
		t.Errorf("final state = %q, want %q", job.State, store.StateCompleted)
	}
}

// TestAsyncSQLiteMirrorConsistency verifies that admin write operations
// (which use applyOpConsistent) provide read-after-write consistency even
// when the SQLite mirror runs in async mode (the production default).
func TestAsyncSQLiteMirrorConsistency(t *testing.T) {
	s := testStoreAsync(t)

	// Create an API key and immediately read it back from SQLite.
	// Without the flush barrier, this read would return 0 rows because
	// the async mirror hasn't processed the write yet.
	now := time.Now().UTC().Format(time.RFC3339Nano)
	err := s.UpsertAPIKey(store.UpsertAPIKeyOp{
		KeyHash:   "testhash123",
		Name:      "test-key",
		Namespace: "default",
		Role:      "admin",
		Enabled:   1,
		CreatedAt: now,
	})
	if err != nil {
		t.Fatalf("UpsertAPIKey: %v", err)
	}

	// Immediately query SQLite — this must see the key.
	var count int
	if err := s.ReadDB().QueryRow(
		"SELECT COUNT(*) FROM api_keys WHERE key_hash = ?", "testhash123",
	).Scan(&count); err != nil {
		t.Fatalf("query api_keys: %v", err)
	}
	if count != 1 {
		t.Fatalf("api_keys count = %d after UpsertAPIKey, want 1 (async mirror not flushed?)", count)
	}

	// Delete the key and verify it's gone immediately.
	if err := s.DeleteAPIKey("testhash123"); err != nil {
		t.Fatalf("DeleteAPIKey: %v", err)
	}
	if err := s.ReadDB().QueryRow(
		"SELECT COUNT(*) FROM api_keys WHERE key_hash = ?", "testhash123",
	).Scan(&count); err != nil {
		t.Fatalf("query api_keys after delete: %v", err)
	}
	if count != 0 {
		t.Fatalf("api_keys count = %d after DeleteAPIKey, want 0 (async mirror not flushed?)", count)
	}
}

func TestFetchRespectsDependsOn(t *testing.T) {
	s := testStore(t)

	root, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "deps.queue",
		Payload: json.RawMessage(`{"id":"root"}`),
	})
	if err != nil {
		t.Fatalf("enqueue root: %v", err)
	}
	child, err := s.Enqueue(store.EnqueueRequest{
		Queue:     "deps.queue",
		Payload:   json.RawMessage(`{"id":"child"}`),
		DependsOn: []string{root.JobID},
	})
	if err != nil {
		t.Fatalf("enqueue child: %v", err)
	}

	first, err := s.Fetch(store.FetchRequest{
		Queues: []string{"deps.queue"}, WorkerID: "w1", Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("fetch first: %v", err)
	}
	if first == nil || first.JobID != root.JobID {
		t.Fatalf("expected root first, got %#v", first)
	}
	if err := s.Ack(first.JobID, json.RawMessage(`{"ok":true}`)); err != nil {
		t.Fatalf("ack root: %v", err)
	}

	second, err := s.Fetch(store.FetchRequest{
		Queues: []string{"deps.queue"}, WorkerID: "w2", Hostname: "h2",
	})
	if err != nil {
		t.Fatalf("fetch second: %v", err)
	}
	if second == nil || second.JobID != child.JobID {
		t.Fatalf("expected dependent child, got %#v", second)
	}
}

func TestBulkGetJobs(t *testing.T) {
	s := testStore(t)

	// Enqueue three jobs.
	ids := make([]string, 3)
	for i := 0; i < 3; i++ {
		r, err := s.Enqueue(store.EnqueueRequest{
			Queue:   "bulk.queue",
			Payload: json.RawMessage(`{"i":` + strconv.Itoa(i) + `}`),
		})
		if err != nil {
			t.Fatalf("Enqueue %d: %v", i, err)
		}
		ids[i] = r.JobID
	}

	// Fetch all three.
	jobs, err := s.BulkGetJobs(ids)
	if err != nil {
		t.Fatalf("BulkGetJobs: %v", err)
	}
	if len(jobs) != 3 {
		t.Fatalf("got %d jobs, want 3", len(jobs))
	}

	// Verify correct jobs returned.
	got := map[string]bool{}
	for _, j := range jobs {
		got[j.ID] = true
	}
	for _, id := range ids {
		if !got[id] {
			t.Errorf("missing job %s", id)
		}
	}
}

func TestBulkGetJobsMissing(t *testing.T) {
	s := testStore(t)

	r, _ := s.Enqueue(store.EnqueueRequest{Queue: "bulk.queue", Payload: json.RawMessage(`{}`)})

	// Mix existing and non-existing IDs.
	jobs, err := s.BulkGetJobs([]string{r.JobID, "nonexistent-id-123"})
	if err != nil {
		t.Fatalf("BulkGetJobs: %v", err)
	}
	if len(jobs) != 1 {
		t.Fatalf("got %d jobs, want 1", len(jobs))
	}
	if jobs[0].ID != r.JobID {
		t.Errorf("got job %s, want %s", jobs[0].ID, r.JobID)
	}
}

func TestBulkGetJobsLimit(t *testing.T) {
	s := testStore(t)

	ids := make([]string, 1001)
	for i := range ids {
		ids[i] = "fake-id"
	}
	_, err := s.BulkGetJobs(ids)
	if err == nil {
		t.Fatal("expected error for >1000 IDs")
	}
}

func TestBulkGetJobsEmpty(t *testing.T) {
	s := testStore(t)

	jobs, err := s.BulkGetJobs([]string{})
	if err != nil {
		t.Fatalf("BulkGetJobs: %v", err)
	}
	if len(jobs) != 0 {
		t.Fatalf("got %d jobs, want 0", len(jobs))
	}
}

// testStoreWithEvents creates a Store with lifecycle events enabled and returns
// both the store and DirectApplier so the caller can read the event log.
func testStoreWithEvents(t *testing.T) (*store.Store, *raft.DirectApplier) {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	da.SetLifecycleEventsEnabled(true)
	t.Cleanup(func() { _ = da.Close() })
	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { _ = s.Close() })
	return s, da
}

func TestHeartbeatProgressEmitsLifecycleEvent(t *testing.T) {
	s, da := testStoreWithEvents(t)

	// Enqueue and fetch a job (transitions: enqueued → started)
	enqResult, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "progress.queue",
		Payload: json.RawMessage(`{"task":"build"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	_, err = s.Fetch(store.FetchRequest{
		Queues:   []string{"progress.queue"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}

	// Send heartbeat with progress data
	progressData := map[string]interface{}{
		"current": 3,
		"total":   9,
		"message": "Building environment",
	}
	_, err = s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
			enqResult.JobID: {
				Progress: progressData,
			},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}

	// Read all lifecycle events
	events, err := da.EventLog(0, 100)
	if err != nil {
		t.Fatalf("EventLog: %v", err)
	}

	// Find the "progress" event
	var progressEvent map[string]any
	for _, ev := range events {
		if ev["type"] == "progress" {
			progressEvent = ev
			break
		}
	}
	if progressEvent == nil {
		t.Fatalf("no progress event found in %d lifecycle events: %v", len(events), events)
	}

	// Verify event fields
	if progressEvent["job_id"] != enqResult.JobID {
		t.Errorf("progress event job_id = %v, want %v", progressEvent["job_id"], enqResult.JobID)
	}
	if progressEvent["queue"] != "progress.queue" {
		t.Errorf("progress event queue = %v, want %q", progressEvent["queue"], "progress.queue")
	}

	// Verify the data payload contains our progress JSON
	dataRaw, ok := progressEvent["data"]
	if !ok {
		t.Fatal("progress event missing data field")
	}
	dataBytes, ok := dataRaw.(json.RawMessage)
	if !ok {
		t.Fatalf("progress event data is %T, want json.RawMessage", dataRaw)
	}
	var data map[string]interface{}
	if err := json.Unmarshal(dataBytes, &data); err != nil {
		t.Fatalf("unmarshal progress data: %v", err)
	}
	if data["message"] != "Building environment" {
		t.Errorf("progress data message = %v, want %q", data["message"], "Building environment")
	}
	if data["current"] != float64(3) {
		t.Errorf("progress data current = %v, want 3", data["current"])
	}
	if data["total"] != float64(9) {
		t.Errorf("progress data total = %v, want 9", data["total"])
	}
}

func TestHeartbeatWithoutProgressNoEvent(t *testing.T) {
	s, da := testStoreWithEvents(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:   "noprog.queue",
		Payload: json.RawMessage(`{}`),
	})
	_, _ = s.Fetch(store.FetchRequest{
		Queues:   []string{"noprog.queue"},
		WorkerID: "w1",
		Hostname: "h1",
	})

	// Heartbeat without progress
	_, err := s.Heartbeat(store.HeartbeatRequest{
		Jobs: map[string]store.HeartbeatJobUpdate{
			enqResult.JobID: {},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}

	events, err := da.EventLog(0, 100)
	if err != nil {
		t.Fatalf("EventLog: %v", err)
	}

	// Should have enqueued + started events, but NO progress event
	for _, ev := range events {
		if ev["type"] == "progress" {
			t.Errorf("unexpected progress event: %v", ev)
		}
	}
}
