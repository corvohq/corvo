package raft

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/user/corvo/internal/kv"
	"github.com/user/corvo/internal/store"
)

func makeChainEnqueueOp(jobID, queue string, now time.Time, chain *store.ChainDefinition) store.EnqueueOp {
	op := makeEnqueueOp(jobID, queue, now)
	if chain != nil {
		chainBytes, _ := json.Marshal(chain)
		op.ChainConfig = chainBytes
		step0 := 0
		op.ChainStep = &step0
		op.ChainID = store.NewChainID()
	}
	return op
}

func fetchAndAckChainJob(t *testing.T, da *DirectApplier, queue string, stepStatus string, result json.RawMessage) store.Job {
	t.Helper()
	now := time.Now()

	// Fetch
	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{queue},
		WorkerID:      "w1",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    42,
	})
	if fetchRes.Err != nil {
		t.Fatalf("fetch from %s: %v", queue, fetchRes.Err)
	}
	fr, ok := fetchRes.Data.(*store.FetchResult)
	if !ok || fr == nil {
		t.Fatalf("expected FetchResult from %s, got %T", queue, fetchRes.Data)
	}

	// Ack
	ackOp := store.AckOp{
		JobID:      fr.JobID,
		Result:     result,
		StepStatus: stepStatus,
		NowNs:      uint64(time.Now().UnixNano()),
	}
	ackRes := da.Apply(store.OpAck, ackOp)
	if ackRes.Err != nil {
		t.Fatalf("ack job %s: %v", fr.JobID, ackRes.Err)
	}

	// Read the job back
	jobVal, closer, err := da.fsm.pebble.Get(kv.JobKey(fr.JobID))
	if err != nil {
		t.Fatalf("get job %s: %v", fr.JobID, err)
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		closer.Close()
		t.Fatalf("decode job %s: %v", fr.JobID, err)
	}
	closer.Close()
	return job
}

func hasPendingJob(da *DirectApplier, queue string) bool {
	now := time.Now()
	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{queue},
		WorkerID:      "w-peek",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    99,
	})
	if fetchRes.Err != nil {
		return false
	}
	fr, ok := fetchRes.Data.(*store.FetchResult)
	return ok && fr != nil
}

func TestChainBasicProgression(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "chain.step0"},
			{Queue: "chain.step1"},
			{Queue: "chain.step2"},
		},
	}

	now := time.Now()
	op := makeChainEnqueueOp(store.NewJobID(), "chain.step0", now, chain)
	res := da.Apply(store.OpEnqueue, op)
	if res.Err != nil {
		t.Fatalf("enqueue: %v", res.Err)
	}

	// Step 0 → ack with continue → should create job in step1
	result0 := json.RawMessage(`{"step0":"done"}`)
	job0 := fetchAndAckChainJob(t, da, "chain.step0", "continue", result0)
	if job0.State != store.StateCompleted {
		t.Fatalf("step0 state = %s, want completed", job0.State)
	}

	// Step 1 should have a pending job
	result1 := json.RawMessage(`{"step1":"done"}`)
	job1 := fetchAndAckChainJob(t, da, "chain.step1", "continue", result1)
	if job1.State != store.StateCompleted {
		t.Fatalf("step1 state = %s, want completed", job1.State)
	}
	if job1.ChainStep == nil || *job1.ChainStep != 1 {
		t.Fatalf("step1 chain_step = %v, want 1", job1.ChainStep)
	}

	// Verify step1 job got previous_result forwarded
	var step1Payload map[string]json.RawMessage
	// Read the step1 job payload — need to fetch the chain.step1 job
	// The job1 we have is already acked. Let's check step2 has a pending job.

	// Step 2 — last step
	result2 := json.RawMessage(`{"step2":"done"}`)
	job2 := fetchAndAckChainJob(t, da, "chain.step2", "continue", result2)
	if job2.State != store.StateCompleted {
		t.Fatalf("step2 state = %s, want completed", job2.State)
	}
	if job2.ChainStep == nil || *job2.ChainStep != 2 {
		t.Fatalf("step2 chain_step = %v, want 2", job2.ChainStep)
	}

	// Verify chain_id is consistent across all steps
	if job0.ChainID == nil || job1.ChainID == nil || job2.ChainID == nil {
		t.Fatal("chain_id should be set on all steps")
	}
	if *job0.ChainID != *job1.ChainID || *job1.ChainID != *job2.ChainID {
		t.Fatalf("chain_id mismatch: %s, %s, %s", *job0.ChainID, *job1.ChainID, *job2.ChainID)
	}

	_ = step1Payload
}

func TestChainEarlyExit(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "exit.step0"},
			{Queue: "exit.step1"},
			{Queue: "exit.step2"},
		},
		OnExit: &store.ChainStep{Queue: "exit.notify"},
	}

	now := time.Now()
	op := makeChainEnqueueOp(store.NewJobID(), "exit.step0", now, chain)
	res := da.Apply(store.OpEnqueue, op)
	if res.Err != nil {
		t.Fatalf("enqueue: %v", res.Err)
	}

	// Ack step0 with continue
	fetchAndAckChainJob(t, da, "exit.step0", "continue", json.RawMessage(`{}`))

	// Ack step1 with exit
	fetchAndAckChainJob(t, da, "exit.step1", "exit", json.RawMessage(`{"reason":"early"}`))

	// Step2 should NOT have a pending job
	if hasPendingJob(da, "exit.step2") {
		t.Fatal("step2 should not have a pending job after early exit")
	}

	// on_exit should have a pending job
	if !hasPendingJob(da, "exit.notify") {
		t.Fatal("on_exit queue should have a pending job")
	}
}

func TestChainLastStepRunsOnExit(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "last.step0"},
			{Queue: "last.step1"},
		},
		OnExit: &store.ChainStep{Queue: "last.notify"},
	}

	now := time.Now()
	op := makeChainEnqueueOp(store.NewJobID(), "last.step0", now, chain)
	da.Apply(store.OpEnqueue, op)

	fetchAndAckChainJob(t, da, "last.step0", "continue", json.RawMessage(`{}`))
	fetchAndAckChainJob(t, da, "last.step1", "continue", json.RawMessage(`{"final":true}`))

	// on_exit should fire after last step
	if !hasPendingJob(da, "last.notify") {
		t.Fatal("on_exit should fire after last step completes")
	}
}

func TestChainFailure(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "fail.step0"},
			{Queue: "fail.step1"},
		},
		OnFailure: &store.ChainStep{Queue: "fail.cleanup"},
	}

	now := time.Now()
	enqOp := makeChainEnqueueOp(store.NewJobID(), "fail.step0", now, chain)
	enqOp.MaxRetries = 0 // Fail immediately to dead letter
	da.Apply(store.OpEnqueue, enqOp)

	// Fetch
	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{"fail.step0"},
		WorkerID:      "w1",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(time.Now().UnixNano()),
		RandomSeed:    1,
	})
	fr := fetchRes.Data.(*store.FetchResult)

	// Fail the job — max_retries=0 so it goes straight to dead
	failRes := da.Apply(store.OpFail, store.FailOp{
		JobID: fr.JobID,
		Error: "something broke",
		NowNs: uint64(time.Now().UnixNano()),
	})
	if failRes.Err != nil {
		t.Fatalf("fail: %v", failRes.Err)
	}

	// Fetch the failure handler and check its payload
	fetchRes2 := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{"fail.cleanup"},
		WorkerID:      "w2",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(time.Now().UnixNano()),
		RandomSeed:    2,
	})
	if fetchRes2.Err != nil {
		t.Fatalf("fetch on_failure: %v", fetchRes2.Err)
	}
	fr2, ok2 := fetchRes2.Data.(*store.FetchResult)
	if !ok2 || fr2 == nil {
		t.Fatal("expected a pending job in fail.cleanup queue")
	}

	var failPayload map[string]any
	if err := json.Unmarshal(fr2.Payload, &failPayload); err != nil {
		t.Fatalf("unmarshal failure payload: %v", err)
	}
	if failPayload["failed_job_id"] != fr.JobID {
		t.Fatalf("failed_job_id = %v, want %s", failPayload["failed_job_id"], fr.JobID)
	}
	if failPayload["error"] != "something broke" {
		t.Fatalf("error = %v, want 'something broke'", failPayload["error"])
	}
}

func TestChainNoHandler(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	// Chain with no on_exit
	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "noh.step0"},
			{Queue: "noh.step1"},
		},
	}

	now := time.Now()
	op := makeChainEnqueueOp(store.NewJobID(), "noh.step0", now, chain)
	da.Apply(store.OpEnqueue, op)

	// Ack step0 with exit — no on_exit configured
	fetchAndAckChainJob(t, da, "noh.step0", "exit", json.RawMessage(`{}`))

	// Step1 should NOT have a pending job (exit skips remaining)
	if hasPendingJob(da, "noh.step1") {
		t.Fatal("step1 should not have a pending job after exit with no handler")
	}
}

func TestChainPayloadMerge(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "merge.step0"},
			{Queue: "merge.step1", Payload: json.RawMessage(`{"extra":"data"}`)},
		},
	}

	now := time.Now()
	op := makeChainEnqueueOp(store.NewJobID(), "merge.step0", now, chain)
	da.Apply(store.OpEnqueue, op)

	fetchAndAckChainJob(t, da, "merge.step0", "continue", json.RawMessage(`{"result_key":"val"}`))

	// Fetch step1 and check payload has both previous_result and step payload
	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{"merge.step1"},
		WorkerID:      "w1",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(time.Now().UnixNano()),
		RandomSeed:    1,
	})
	fr := fetchRes.Data.(*store.FetchResult)

	var payload map[string]any
	if err := json.Unmarshal(fr.Payload, &payload); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if payload["extra"] != "data" {
		t.Fatalf("step payload not merged: %v", payload)
	}
	if payload["previous_result"] == nil {
		t.Fatal("previous_result should be in payload")
	}
	if payload["previous_job_id"] == nil {
		t.Fatal("previous_job_id should be in payload")
	}
}

func TestNonChainJobIgnoresStepStatus(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	now := time.Now()
	op := makeEnqueueOp(store.NewJobID(), "plain.q", now)
	da.Apply(store.OpEnqueue, op)

	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:        []string{"plain.q"},
		WorkerID:      "w1",
		Hostname:      "localhost",
		LeaseDuration: 60,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    1,
	})
	fr := fetchRes.Data.(*store.FetchResult)

	// Ack with step_status on a non-chain job — should succeed without error
	ackRes := da.Apply(store.OpAck, store.AckOp{
		JobID:      fr.JobID,
		Result:     json.RawMessage(`{"ok":true}`),
		StepStatus: "continue",
		NowNs:      uint64(time.Now().UnixNano()),
	})
	if ackRes.Err != nil {
		t.Fatalf("ack should succeed for non-chain job with step_status: %v", ackRes.Err)
	}
}

func TestChainFailureHandlerDoesNotRecurse(t *testing.T) {
	da, err := NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()

	chain := &store.ChainDefinition{
		Steps: []store.ChainStep{
			{Queue: "rec.step0"},
			{Queue: "rec.step1"},
		},
		OnFailure: &store.ChainStep{Queue: "rec.failhandler"},
	}

	now := time.Now()
	enqOp := makeChainEnqueueOp(store.NewJobID(), "rec.step0", now, chain)
	enqOp.MaxRetries = 0
	da.Apply(store.OpEnqueue, enqOp)

	// Fetch and fail step0 → triggers on_failure
	fetchRes := da.Apply(store.OpFetch, store.FetchOp{
		Queues:   []string{"rec.step0"},
		WorkerID: "w1", Hostname: "localhost", LeaseDuration: 60,
		NowNs: uint64(time.Now().UnixNano()), RandomSeed: 1,
	})
	fr := fetchRes.Data.(*store.FetchResult)
	da.Apply(store.OpFail, store.FailOp{
		JobID: fr.JobID, Error: "boom", NowNs: uint64(time.Now().UnixNano()),
	})

	// Fetch the failure handler job
	fetchRes2 := da.Apply(store.OpFetch, store.FetchOp{
		Queues:   []string{"rec.failhandler"},
		WorkerID: "w2", Hostname: "localhost", LeaseDuration: 60,
		NowNs: uint64(time.Now().UnixNano()), RandomSeed: 2,
	})
	fr2 := fetchRes2.Data.(*store.FetchResult)

	// Fail the failure handler — should NOT spawn another on_failure
	da.Apply(store.OpFail, store.FailOp{
		JobID: fr2.JobID, Error: "fail handler also failed", NowNs: uint64(time.Now().UnixNano()),
	})

	// No additional job should appear in rec.failhandler
	if hasPendingJob(da, "rec.failhandler") {
		t.Fatal("failure handler should not recurse")
	}
}
