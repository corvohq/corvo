package store_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/user/corvo/internal/raft"
	"github.com/user/corvo/internal/store"
)

// testStore creates a Store backed by a DirectApplier for testing.
func testStore(t *testing.T) *store.Store {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })
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

	s.Enqueue(store.EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"normal"}`), Priority: "normal"})
	s.Enqueue(store.EnqueueRequest{Queue: "prio.queue", Payload: json.RawMessage(`{"p":"critical"}`), Priority: "critical"})

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

	s.Enqueue(store.EnqueueRequest{Queue: "paused.queue", Payload: json.RawMessage(`{}`)})
	s.PauseQueue("paused.queue")

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
	s.Fetch(store.FetchRequest{Queues: []string{"ack.queue"}, WorkerID: "w", Hostname: "h"})

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
	s.Fetch(store.FetchRequest{Queues: []string{"unique.queue"}, WorkerID: "w", Hostname: "h"})
	s.Ack(enqResult.JobID, nil)

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
	s.Fetch(store.FetchRequest{Queues: []string{"fail.queue"}, WorkerID: "w", Hostname: "h"})

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
	s.Fetch(store.FetchRequest{Queues: []string{"dead.queue"}, WorkerID: "w", Hostname: "h"})

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

func TestFailProviderErrorAdvancesRoutingTarget(t *testing.T) {
	s := testStore(t)

	maxRetries := 3
	enqResult, _ := s.Enqueue(store.EnqueueRequest{
		Queue:      "route.queue",
		Payload:    json.RawMessage(`{}`),
		MaxRetries: &maxRetries,
		Routing: &store.RoutingConfig{
			Prefer:   "model-a",
			Fallback: []string{"model-b", "model-c"},
			Strategy: "fallback_on_error",
		},
	})
	if _, err := s.Fetch(store.FetchRequest{Queues: []string{"route.queue"}, WorkerID: "w", Hostname: "h"}); err != nil {
		t.Fatalf("Fetch() error: %v", err)
	}

	result, err := s.Fail(enqResult.JobID, "provider timeout", "", true)
	if err != nil {
		t.Fatalf("Fail() error: %v", err)
	}
	if result.Status != store.StateRetrying {
		t.Fatalf("Fail() status = %q, want %q", result.Status, store.StateRetrying)
	}

	job, err := s.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if !job.ProviderError {
		t.Fatalf("provider_error = false, want true")
	}
	if job.RoutingTarget == nil || *job.RoutingTarget != "model-b" {
		t.Fatalf("routing_target = %v, want model-b", job.RoutingTarget)
	}
	if job.RoutingIndex != 1 {
		t.Fatalf("routing_index = %d, want 1", job.RoutingIndex)
	}
}

func TestHeartbeatExtendsLease(t *testing.T) {
	s := testStore(t)

	enqResult, _ := s.Enqueue(store.EnqueueRequest{Queue: "hb.queue", Payload: json.RawMessage(`{}`)})
	s.Fetch(store.FetchRequest{Queues: []string{"hb.queue"}, WorkerID: "w", Hostname: "h"})

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
	s.Fetch(store.FetchRequest{Queues: []string{"prog.queue"}, WorkerID: "w", Hostname: "h"})

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
	s.Fetch(store.FetchRequest{Queues: []string{"cp.queue"}, WorkerID: "w", Hostname: "h"})

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
	s.Fetch(store.FetchRequest{Queues: []string{"cancel.queue"}, WorkerID: "w", Hostname: "h"})

	// Cancel the job via the proper API
	s.CancelJob(enqResult.JobID)

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
	s.ReadDB().QueryRow("SELECT total, pending FROM batches WHERE id = ?", result.BatchID).Scan(&total, &pending)
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
		s.Ack(r.JobID, nil)
	}

	// Verify callback job was enqueued
	var count int
	s.ReadDB().QueryRow("SELECT COUNT(*) FROM jobs WHERE queue = 'batch.done'").Scan(&count)
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
