package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/corvohq/corvo/internal/kv"
	"github.com/corvohq/corvo/internal/store"
)

// --- Enqueue ---

func (f *FSM) applyEnqueue(data json.RawMessage) *store.OpResult {
	var op store.EnqueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyEnqueueOp(op)
}

func (f *FSM) applyEnqueueOp(op store.EnqueueOp) *store.OpResult {

	// Check unique lock if needed
	if op.UniqueKey != "" {
		uk := kv.UniqueKey(op.Queue, op.UniqueKey)
		val, closer, err := f.pebble.Get(uk)
		if err == nil {
			defer closer.Close()
			jobID, expiresNs := kv.DecodeUniqueValue(val)
			if expiresNs > op.NowNs {
				// Lock still valid — return existing job
				return &store.OpResult{Data: &store.EnqueueResult{
					JobID:          jobID,
					Status:         "duplicate",
					UniqueExisting: true,
				}}
			}
		} else if err != pebble.ErrNotFound {
			return &store.OpResult{Err: fmt.Errorf("check unique: %w", err)}
		}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	jobData, _ := encodeJobDoc(jobToDoc(op))
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
	batch.Set(kv.QueueNameKey(op.Queue), nil, f.writeOpts)

	// Add to appropriate queue structure.
	createdNs := uint64(op.CreatedAt.UnixNano())
	if op.State == store.StateScheduled && op.ScheduledAt != nil {
		schedNs := uint64(op.ScheduledAt.UnixNano())
		batch.Set(kv.ScheduledKey(op.Queue, schedNs, op.JobID), nil, f.writeOpts)
	} else {
		// Hot path for default jobs: append-first queue log.
		// Keep priority-indexed pending keys for non-normal priority.
		if op.Priority == store.PriorityNormal {
			batch.Set(kv.QueueAppendKey(op.Queue, createdNs, op.JobID), nil, f.writeOpts)
		} else {
			batch.Set(kv.PendingKey(op.Queue, uint8(op.Priority), createdNs, op.JobID), nil, f.writeOpts)
		}
	}

	// Set unique lock
	if op.UniqueKey != "" {
		period := op.UniquePeriod
		if period <= 0 {
			period = 3600
		}
		expiresNs := op.NowNs + uint64(period)*1_000_000_000
		batch.Set(kv.UniqueKey(op.Queue, op.UniqueKey), kv.EncodeUniqueValue(op.JobID, expiresNs), f.writeOpts)
	}
	if err := f.appendLifecycleEvent(batch, "enqueued", op.JobID, op.Queue, op.NowNs); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteInsertJob(db, op)
	})

	return &store.OpResult{Data: &store.EnqueueResult{
		JobID:  op.JobID,
		Status: op.State,
	}}
}

func (f *FSM) applyMultiEnqueue(ops []store.EnqueueOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))
	if len(ops) == 0 {
		return &store.OpResult{Data: results}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	type uniqueLock struct {
		jobID     string
		expiresNs uint64
	}
	pendingUnique := make(map[string]uniqueLock, len(ops))
	inserted := make([]store.EnqueueOp, 0, len(ops))

	for i, op := range ops {
		// Check unique lock if needed.
		if op.UniqueKey != "" {
			ukey := kv.UniqueKey(op.Queue, op.UniqueKey)
			ukeyS := string(ukey)
			if v, ok := pendingUnique[ukeyS]; ok && v.expiresNs > op.NowNs {
				results[i] = &store.OpResult{Data: &store.EnqueueResult{
					JobID:          v.jobID,
					Status:         "duplicate",
					UniqueExisting: true,
				}}
				continue
			}
			val, closer, err := f.pebble.Get(ukey)
			if err == nil {
				jobID, expiresNs := kv.DecodeUniqueValue(val)
				closer.Close()
				if expiresNs > op.NowNs {
					results[i] = &store.OpResult{Data: &store.EnqueueResult{
						JobID:          jobID,
						Status:         "duplicate",
						UniqueExisting: true,
					}}
					pendingUnique[ukeyS] = uniqueLock{jobID: jobID, expiresNs: expiresNs}
					continue
				}
			} else if err != pebble.ErrNotFound {
				results[i] = &store.OpResult{Err: fmt.Errorf("check unique: %w", err)}
				continue
			}
		}

		jobData, _ := encodeJobDoc(jobToDoc(op))
		if err := batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts); err != nil {
			results[i] = &store.OpResult{Err: err}
			continue
		}
		if err := batch.Set(kv.QueueNameKey(op.Queue), nil, f.writeOpts); err != nil {
			results[i] = &store.OpResult{Err: err}
			continue
		}

		createdNs := uint64(op.CreatedAt.UnixNano())
		if op.State == store.StateScheduled && op.ScheduledAt != nil {
			schedNs := uint64(op.ScheduledAt.UnixNano())
			if err := batch.Set(kv.ScheduledKey(op.Queue, schedNs, op.JobID), nil, f.writeOpts); err != nil {
				results[i] = &store.OpResult{Err: err}
				continue
			}
		} else {
			if op.Priority == store.PriorityNormal {
				if err := batch.Set(kv.QueueAppendKey(op.Queue, createdNs, op.JobID), nil, f.writeOpts); err != nil {
					results[i] = &store.OpResult{Err: err}
					continue
				}
			} else {
				if err := batch.Set(kv.PendingKey(op.Queue, uint8(op.Priority), createdNs, op.JobID), nil, f.writeOpts); err != nil {
					results[i] = &store.OpResult{Err: err}
					continue
				}
			}
		}

		if op.UniqueKey != "" {
			period := op.UniquePeriod
			if period <= 0 {
				period = 3600
			}
			expiresNs := op.NowNs + uint64(period)*1_000_000_000
			ukey := kv.UniqueKey(op.Queue, op.UniqueKey)
			if err := batch.Set(ukey, kv.EncodeUniqueValue(op.JobID, expiresNs), f.writeOpts); err != nil {
				results[i] = &store.OpResult{Err: err}
				continue
			}
			pendingUnique[string(ukey)] = uniqueLock{jobID: op.JobID, expiresNs: expiresNs}
		}

		if err := f.appendLifecycleEvent(batch, "enqueued", op.JobID, op.Queue, op.NowNs); err != nil {
			results[i] = &store.OpResult{Err: err}
			continue
		}

		inserted = append(inserted, op)
		results[i] = &store.OpResult{Data: &store.EnqueueResult{
			JobID:  op.JobID,
			Status: op.State,
		}}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = &store.OpResult{Err: err}
			}
		}
		return &store.OpResult{Data: results}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
			}
		}
		return &store.OpResult{Data: results}
	}

	if len(inserted) > 0 {
		f.syncSQLite(func(db sqlExecer) error {
			for _, op := range inserted {
				if err := sqliteInsertJob(db, op); err != nil {
					return err
				}
			}
			return nil
		})
	}

	return &store.OpResult{Data: results}
}

// --- EnqueueBatch ---

func (f *FSM) applyEnqueueBatch(data json.RawMessage) *store.OpResult {
	var op store.EnqueueBatchOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyEnqueueBatchOp(op)
}

func (f *FSM) applyEnqueueBatchOp(op store.EnqueueBatchOp) *store.OpResult {

	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Create batch record if needed
	if op.BatchID != "" && op.Batch != nil {
		batchDoc := store.Batch{
			ID:        op.BatchID,
			Total:     len(op.Jobs),
			Pending:   len(op.Jobs),
			CreatedAt: time.Unix(0, int64(op.Jobs[0].NowNs)),
		}
		if op.Batch.CallbackQueue != "" {
			batchDoc.CallbackQueue = &op.Batch.CallbackQueue
		}
		if len(op.Batch.CallbackPayload) > 0 {
			batchDoc.CallbackPayload = op.Batch.CallbackPayload
		}
		batchData, _ := json.Marshal(batchDoc)
		batch.Set(kv.BatchKey(op.BatchID), batchData, f.writeOpts)
	}

	jobIDs := make([]string, len(op.Jobs))
	for i := range op.Jobs {
		op.Jobs[i].BatchID = op.BatchID // propagate batch ID to each job
		j := op.Jobs[i]
		jobIDs[i] = j.JobID
		jobData, _ := encodeJobDoc(jobToDoc(j))
		batch.Set(kv.JobKey(j.JobID), jobData, f.writeOpts)
		batch.Set(kv.QueueNameKey(j.Queue), nil, f.writeOpts)
		createdNs := uint64(j.CreatedAt.UnixNano())
		if j.Priority == store.PriorityNormal {
			batch.Set(kv.QueueAppendKey(j.Queue, createdNs, j.JobID), nil, f.writeOpts)
		} else {
			batch.Set(kv.PendingKey(j.Queue, uint8(j.Priority), createdNs, j.JobID), nil, f.writeOpts)
		}
		if err := f.appendLifecycleEvent(batch, "enqueued", j.JobID, j.Queue, j.NowNs); err != nil {
			return &store.OpResult{Err: err}
		}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteInsertBatch(db, op)
	})

	return &store.OpResult{Data: &store.BatchEnqueueResult{
		JobIDs:  jobIDs,
		BatchID: op.BatchID,
	}}
}

func (f *FSM) applyMultiEnqueueBatch(ops []store.EnqueueBatchOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))
	if len(ops) == 0 {
		return &store.OpResult{Data: results}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	for i, op := range ops {
		if op.BatchID != "" && op.Batch != nil {
			createdAt := time.Now()
			if len(op.Jobs) > 0 {
				createdAt = time.Unix(0, int64(op.Jobs[0].NowNs))
			}
			batchDoc := store.Batch{
				ID:        op.BatchID,
				Total:     len(op.Jobs),
				Pending:   len(op.Jobs),
				CreatedAt: createdAt,
			}
			if op.Batch.CallbackQueue != "" {
				batchDoc.CallbackQueue = &op.Batch.CallbackQueue
			}
			if len(op.Batch.CallbackPayload) > 0 {
				batchDoc.CallbackPayload = op.Batch.CallbackPayload
			}
			batchData, _ := json.Marshal(batchDoc)
			batch.Set(kv.BatchKey(op.BatchID), batchData, f.writeOpts)
		}

		jobIDs := make([]string, len(op.Jobs))
		for j := range op.Jobs {
			op.Jobs[j].BatchID = op.BatchID
			job := op.Jobs[j]
			jobIDs[j] = job.JobID

			jobData, _ := encodeJobDoc(jobToDoc(job))
			batch.Set(kv.JobKey(job.JobID), jobData, f.writeOpts)
			batch.Set(kv.QueueNameKey(job.Queue), nil, f.writeOpts)
			createdNs := uint64(job.CreatedAt.UnixNano())
			if job.Priority == store.PriorityNormal {
				batch.Set(kv.QueueAppendKey(job.Queue, createdNs, job.JobID), nil, f.writeOpts)
			} else {
				batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, job.JobID), nil, f.writeOpts)
			}

			if err := f.appendLifecycleEvent(batch, "enqueued", job.JobID, job.Queue, job.NowNs); err != nil {
				return &store.OpResult{Err: err}
			}
		}

		results[i] = &store.OpResult{Data: &store.BatchEnqueueResult{
			JobIDs:  jobIDs,
			BatchID: op.BatchID,
		}}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = &store.OpResult{Err: err}
			}
		}
		return &store.OpResult{Data: results}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
			}
		}
		return &store.OpResult{Data: results}
	}

	f.syncSQLite(func(db sqlExecer) error {
		for _, op := range ops {
			if err := sqliteInsertBatch(db, op); err != nil {
				return err
			}
		}
		return nil
	})

	return &store.OpResult{Data: results}
}

// --- Fetch ---

func (f *FSM) applyFetch(data json.RawMessage) *store.OpResult {
	var op store.FetchOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyFetchOp(op)
}

func (f *FSM) applyFetchOp(op store.FetchOp) *store.OpResult {

	nowNs := op.NowNs
	leaseDuration := op.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}
	leaseExpiresNs := nowNs + uint64(leaseDuration)*1_000_000_000

	// Try each queue in order
	for _, queue := range op.Queues {
		// Check if queue is paused
		qcKey := kv.QueueConfigKey(queue)
		hasRateLimit := false
		if qcVal, closer, err := f.pebble.Get(qcKey); err == nil {
			var qc store.Queue
			if err := json.Unmarshal(qcVal, &qc); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if qc.Paused {
				continue
			}

			// Check concurrency limit
			if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
				activeCount := f.getActiveCount(queue)
				if activeCount >= *qc.MaxConcurrency {
					continue
				}
			}

			// Check rate limit
			if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
				hasRateLimit = true
				windowNs := uint64(*qc.RateWindowMs) * 1_000_000
				windowStart := nowNs - windowNs
				count := countPrefixFrom(f.pebble, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
				if count >= *qc.RateLimit {
					continue
				}
			}
		}

		jobID, pendingKey, appendKey, job, ok := f.findPendingOrAppendJobForQueue(queue, nil)
		if !ok {
			continue
		}

		// Apply the fetch: update job, move from pending to active
		batch := f.pebble.NewBatch()
		defer batch.Close()
		job.State = store.StateActive
		job.WorkerID = &op.WorkerID
		job.Hostname = &op.Hostname
		job.Attempt++
		startedAt := time.Unix(0, int64(nowNs))
		job.StartedAt = &startedAt
		leaseExp := time.Unix(0, int64(leaseExpiresNs))
		job.LeaseExpiresAt = &leaseExp

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
		if len(pendingKey) > 0 {
			batch.Delete(pendingKey, f.writeOpts)
		}
		if len(appendKey) > 0 {
			batch.Delete(appendKey, f.writeOpts)
			batch.Set(kv.QueueCursorKey(queue), appendKey, f.writeOpts)
		}
		batch.Set(kv.ActiveKey(queue, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
		f.incrActive(queue)

		// Record rate limit entry
		if hasRateLimit {
			batch.Set(kv.RateLimitKey(queue, nowNs, op.RandomSeed), nil, f.writeOpts)
		}

		// Upsert worker
		worker := store.Worker{
			ID:            op.WorkerID,
			Queues:        marshalStringSlice(op.Queues),
			LastHeartbeat: startedAt,
			StartedAt:     startedAt,
		}
		if op.Hostname != "" {
			worker.Hostname = &op.Hostname
		}
		workerData, _ := json.Marshal(worker)
		batch.Set(kv.WorkerKey(op.WorkerID), workerData, f.writeOpts)
		if err := f.appendLifecycleEvent(batch, "started", jobID, queue, nowNs); err != nil {
			return &store.OpResult{Err: err}
		}
		if err := f.appendLifecycleCursor(batch); err != nil {
			return &store.OpResult{Err: err}
		}

		if err := batch.Commit(f.writeOpts); err != nil {
			return &store.OpResult{Err: fmt.Errorf("pebble commit fetch: %w", err)}
		}

		f.syncSQLite(func(db sqlExecer) error {
			return sqliteFetchJob(db, job, op)
		})

		result := &store.FetchResult{
			JobID:         jobID,
			Queue:         queue,
			Payload:       job.Payload,
			Attempt:       job.Attempt,
			MaxRetries:    job.MaxRetries,
			LeaseDuration: leaseDuration,
			Tags:          job.Tags,
			Checkpoint:    job.Checkpoint,
			Agent:         job.Agent,
		}
		return &store.OpResult{Data: result}
	}

	// No job found
	return &store.OpResult{Data: (*store.FetchResult)(nil)}
}

func (f *FSM) applyFetchBatch(data json.RawMessage) *store.OpResult {
	var op store.FetchBatchOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyFetchBatchOp(op)
}

func (f *FSM) applyFetchBatchOp(op store.FetchBatchOp) *store.OpResult {
	if len(op.CandidateJobIDs) > 0 {
		return f.applyFetchBatchPreresolved(op)
	}
	if len(op.Queues) == 0 || op.Count <= 0 {
		return &store.OpResult{Data: []store.FetchResult{}}
	}

	nowNs := op.NowNs
	leaseDuration := op.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}
	leaseExpiresNs := nowNs + uint64(leaseDuration)*1_000_000_000

	batch := f.pebble.NewBatch()
	defer batch.Close()

	startedAt := time.Unix(0, int64(nowNs))
	leaseExp := time.Unix(0, int64(leaseExpiresNs))
	worker := store.Worker{
		ID:            op.WorkerID,
		Queues:        marshalStringSlice(op.Queues),
		LastHeartbeat: startedAt,
		StartedAt:     startedAt,
	}
	if op.Hostname != "" {
		worker.Hostname = &op.Hostname
	}
	workerData, _ := json.Marshal(worker)
	batch.Set(kv.WorkerKey(op.WorkerID), workerData, f.writeOpts)

	type queueState struct {
		name        string
		activeLimit int
		activeCount int
		rateLimit   int
		rateCount   int
	}

	states := make([]queueState, 0, len(op.Queues))
	for _, queue := range op.Queues {
		qs := queueState{name: queue}

		qcKey := kv.QueueConfigKey(queue)
		if qcVal, closer, err := f.pebble.Get(qcKey); err == nil {
			var qc store.Queue
			if err := json.Unmarshal(qcVal, &qc); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if qc.Paused {
				continue
			}
			if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
				qs.activeLimit = *qc.MaxConcurrency
				qs.activeCount = f.getActiveCount(queue)
			}
			if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
				qs.rateLimit = *qc.RateLimit
				windowNs := uint64(*qc.RateWindowMs) * 1_000_000
				windowStart := nowNs - windowNs
				qs.rateCount = countPrefixFrom(f.pebble, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
			}
		}

		states = append(states, qs)
	}

	results := make([]store.FetchResult, 0, op.Count)
	sqliteJobs := make([]store.Job, 0, op.Count)
	claimed := make(map[string]struct{}, op.Count)
	rateSeq := uint64(0)

	for len(results) < op.Count {
		progress := false
		for i := range states {
			qs := &states[i]

			if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
				continue
			}
			if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
				continue
			}

			jobID, pendingKey, appendKey, job, ok := f.findPendingOrAppendJobForQueue(qs.name, claimed)
			if !ok {
				continue
			}

			progress = true
			claimed[jobID] = struct{}{}

			job.State = store.StateActive
			job.WorkerID = &op.WorkerID
			job.Hostname = &op.Hostname
			job.Attempt++
			job.StartedAt = &startedAt
			job.LeaseExpiresAt = &leaseExp

			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if len(pendingKey) > 0 {
				batch.Delete(pendingKey, f.writeOpts)
			}
			if len(appendKey) > 0 {
				batch.Delete(appendKey, f.writeOpts)
				batch.Set(kv.QueueCursorKey(qs.name), appendKey, f.writeOpts)
			}
			batch.Set(kv.ActiveKey(qs.name, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
			f.incrActive(qs.name)
			if qs.rateLimit > 0 {
				batch.Set(kv.RateLimitKey(qs.name, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
				rateSeq++
				qs.rateCount++
			}
			if err := f.appendLifecycleEvent(batch, "started", jobID, qs.name, nowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			if qs.activeLimit > 0 {
				qs.activeCount++
			}

			sqliteJobs = append(sqliteJobs, job)
			results = append(results, store.FetchResult{
				JobID:         jobID,
				Queue:         qs.name,
				Payload:       job.Payload,
				Attempt:       job.Attempt,
				MaxRetries:    job.MaxRetries,
				LeaseDuration: leaseDuration,
				Tags:          job.Tags,
				Checkpoint:    job.Checkpoint,
				Agent:         job.Agent,
			})
			if len(results) >= op.Count {
				break
			}
		}
		if !progress {
			break
		}
	}

	if len(results) == 0 {
		return &store.OpResult{Data: []store.FetchResult{}}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit fetch batch: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		for _, job := range sqliteJobs {
			if err := sqliteFetchJob(db, job, store.FetchOp{
				Queues:        op.Queues,
				WorkerID:      op.WorkerID,
				Hostname:      op.Hostname,
				LeaseDuration: op.LeaseDuration,
				NowNs:         op.NowNs,
				RandomSeed:    op.RandomSeed,
			}); err != nil {
				return err
			}
		}
		return nil
	})

	return &store.OpResult{Data: results}
}

// applyFetchBatchPreresolved handles a FetchBatch where candidates were
// pre-resolved outside the FSM goroutine. Each candidate gets a cheap O(1)
// point lookup instead of an iterator scan.
func (f *FSM) applyFetchBatchPreresolved(op store.FetchBatchOp) *store.OpResult {
	if len(op.Queues) == 0 || op.Count <= 0 {
		return &store.OpResult{Data: []store.FetchResult{}}
	}

	nowNs := op.NowNs
	leaseDuration := op.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}
	leaseExpiresNs := nowNs + uint64(leaseDuration)*1_000_000_000

	batch := f.pebble.NewBatch()
	defer batch.Close()

	startedAt := time.Unix(0, int64(nowNs))
	leaseExp := time.Unix(0, int64(leaseExpiresNs))
	worker := store.Worker{
		ID:            op.WorkerID,
		Queues:        marshalStringSlice(op.Queues),
		LastHeartbeat: startedAt,
		StartedAt:     startedAt,
	}
	if op.Hostname != "" {
		worker.Hostname = &op.Hostname
	}
	workerData, _ := json.Marshal(worker)
	batch.Set(kv.WorkerKey(op.WorkerID), workerData, f.writeOpts)

	// Build per-queue state for concurrency/rate limit checks.
	type queueState struct {
		activeLimit int
		activeCount int
		rateLimit   int
		rateCount   int
	}
	queueStates := make(map[string]*queueState, len(op.Queues))
	for _, queue := range op.Queues {
		qs := &queueState{}
		qcKey := kv.QueueConfigKey(queue)
		if qcVal, closer, err := f.pebble.Get(qcKey); err == nil {
			var qc store.Queue
			if err := json.Unmarshal(qcVal, &qc); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if qc.Paused {
				qs.activeLimit = -1 // sentinel: paused
				queueStates[queue] = qs
				continue
			}
			if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
				qs.activeLimit = *qc.MaxConcurrency
				qs.activeCount = f.getActiveCount(queue)
			}
			if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
				qs.rateLimit = *qc.RateLimit
				windowNs := uint64(*qc.RateWindowMs) * 1_000_000
				windowStart := nowNs - windowNs
				qs.rateCount = countPrefixFrom(f.pebble, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
			}
		}
		queueStates[queue] = qs
	}

	results := make([]store.FetchResult, 0, op.Count)
	sqliteJobs := make([]store.Job, 0, op.Count)
	rateSeq := uint64(0)

	for i, jobID := range op.CandidateJobIDs {
		if len(results) >= op.Count {
			break
		}
		queue := op.CandidateQueues[i]

		qs := queueStates[queue]
		if qs == nil {
			continue
		}
		if qs.activeLimit < 0 {
			continue // paused
		}
		if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
			continue
		}
		if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
			continue
		}

		// O(1) point lookup for the job.
		val, closer, err := f.pebble.Get(kv.JobKey(jobID))
		if err != nil {
			continue // job deleted or not found
		}
		var job store.Job
		if err := decodeJobDoc(val, &job); err != nil {
			closer.Close()
			continue
		}
		closer.Close()

		if job.State != store.StatePending {
			continue // stale candidate
		}
		if !f.dependenciesSatisfied(job) {
			continue
		}

		// Claim the job — same mutation as the scan-based path.
		job.State = store.StateActive
		job.WorkerID = &op.WorkerID
		job.Hostname = &op.Hostname
		job.Attempt++
		job.StartedAt = &startedAt
		job.LeaseExpiresAt = &leaseExp

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)

		// Delete pending/append index keys. We don't know which one exists,
		// so we try to delete the append key based on queue/createdNs and
		// also scan for a pending key. Since we have the job doc, we know
		// createdNs from CreatedAt.
		createdNs := uint64(job.CreatedAt.UnixNano())
		if job.Priority == store.PriorityNormal {
			appendKey := kv.QueueAppendKey(queue, createdNs, jobID)
			batch.Delete(appendKey, f.writeOpts)
			batch.Set(kv.QueueCursorKey(queue), appendKey, f.writeOpts)
		} else {
			pendingKey := kv.PendingKey(queue, uint8(job.Priority), createdNs, jobID)
			batch.Delete(pendingKey, f.writeOpts)
		}

		batch.Set(kv.ActiveKey(queue, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
		f.incrActive(queue)
		if qs.rateLimit > 0 {
			batch.Set(kv.RateLimitKey(queue, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
			rateSeq++
			qs.rateCount++
		}
		if err := f.appendLifecycleEvent(batch, "started", jobID, queue, nowNs); err != nil {
			return &store.OpResult{Err: err}
		}
		if qs.activeLimit > 0 {
			qs.activeCount++
		}

		sqliteJobs = append(sqliteJobs, job)
		results = append(results, store.FetchResult{
			JobID:         jobID,
			Queue:         queue,
			Payload:       job.Payload,
			Attempt:       job.Attempt,
			MaxRetries:    job.MaxRetries,
			LeaseDuration: leaseDuration,
			Tags:          job.Tags,
			Checkpoint:    job.Checkpoint,
			Agent:         job.Agent,
		})
	}

	if len(results) == 0 {
		return &store.OpResult{Data: []store.FetchResult{}}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit fetch batch: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		for _, job := range sqliteJobs {
			if err := sqliteFetchJob(db, job, store.FetchOp{
				Queues:        op.Queues,
				WorkerID:      op.WorkerID,
				Hostname:      op.Hostname,
				LeaseDuration: op.LeaseDuration,
				NowNs:         op.NowNs,
				RandomSeed:    op.RandomSeed,
			}); err != nil {
				return err
			}
		}
		return nil
	})

	return &store.OpResult{Data: results}
}

func (f *FSM) fetchQueueAllowed(queue string, nowNs uint64) bool {
	qcKey := kv.QueueConfigKey(queue)
	qcVal, closer, err := f.pebble.Get(qcKey)
	if err != nil {
		return true
	}
	defer closer.Close()

	var qc store.Queue
	if err := json.Unmarshal(qcVal, &qc); err != nil {
		return false
	}
	if qc.Paused {
		return false
	}
	if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
		activeCount := f.getActiveCount(queue)
		if activeCount >= *qc.MaxConcurrency {
			return false
		}
	}
	if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
		windowNs := uint64(*qc.RateWindowMs) * 1_000_000
		windowStart := nowNs - windowNs
		count := countPrefixFrom(f.pebble, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
		if count >= *qc.RateLimit {
			return false
		}
	}
	return true
}

func (f *FSM) findPendingJobForQueue(queue string, claimed map[string]struct{}) (jobID string, pendingKey []byte, job store.Job, ok bool) {
	prefix := kv.PendingPrefix(queue)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return "", nil, store.Job{}, false
	}
	defer iter.Close()

	for valid := iter.First(); valid; valid = iter.Next() {
		key := iter.Key()
		idOffset := len(prefix) + 1 + 8
		if len(key) <= idOffset {
			continue
		}
		id := string(key[idOffset:])
		if _, exists := claimed[id]; exists {
			continue
		}
		val, closer, err := f.pebble.Get(kv.JobKey(id))
		if err != nil {
			// Orphaned pending key — auto-clean.
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		var doc store.Job
		if err := decodeJobDoc(val, &doc); err != nil {
			closer.Close()
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		closer.Close()
		if doc.State != store.StatePending {
			// Job is no longer pending (completed/cancelled) — auto-clean orphan.
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		if !f.dependenciesSatisfied(doc) {
			continue
		}

		pk := make([]byte, len(key))
		copy(pk, key)
		return id, pk, doc, true
	}
	return "", nil, store.Job{}, false
}

func (f *FSM) findAppendJobForQueue(queue string, claimed map[string]struct{}) (jobID string, appendKey []byte, job store.Job, ok bool) {
	prefix := kv.QueueAppendPrefix(queue)
	var lower []byte
	if cursor, closer, err := f.pebble.Get(kv.QueueCursorKey(queue)); err == nil {
		lower = append([]byte(nil), cursor...)
		closer.Close()
	}

	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return "", nil, store.Job{}, false
	}
	defer iter.Close()

	var valid bool
	hasCursor := len(lower) > 0
	if hasCursor {
		valid = iter.SeekGE(lower)
		if valid && bytes.Equal(iter.Key(), lower) {
			valid = iter.Next()
		}
	} else {
		valid = iter.First()
	}

	for ; valid; valid = iter.Next() {
		key := iter.Key()
		idOffset := len(prefix) + 8
		if len(key) <= idOffset {
			continue
		}
		id := string(key[idOffset:])
		if _, exists := claimed[id]; exists {
			continue
		}

		val, closer, err := f.pebble.Get(kv.JobKey(id))
		if err != nil {
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		var doc store.Job
		if err := decodeJobDoc(val, &doc); err != nil {
			closer.Close()
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		closer.Close()
		if doc.State != store.StatePending {
			k := make([]byte, len(key))
			copy(k, key)
			_ = f.pebble.Delete(k, pebble.NoSync)
			continue
		}
		if !f.dependenciesSatisfied(doc) {
			continue
		}
		ak := make([]byte, len(key))
		copy(ak, key)
		return id, ak, doc, true
	}

	// Cursor-based scan found nothing. Rescan before the cursor to catch
	// entries inserted with timestamps before the cursor position (can
	// happen when concurrent producers have out-of-order timestamps).
	if hasCursor {
		iter2, err := f.pebble.NewIter(&pebble.IterOptions{
			LowerBound: prefix,
			UpperBound: lower,
		})
		if err != nil {
			return "", nil, store.Job{}, false
		}
		defer iter2.Close()

		for valid := iter2.First(); valid; valid = iter2.Next() {
			key := iter2.Key()
			idOffset := len(prefix) + 8
			if len(key) <= idOffset {
				continue
			}
			id := string(key[idOffset:])
			if _, exists := claimed[id]; exists {
				continue
			}
			val, closer, err := f.pebble.Get(kv.JobKey(id))
			if err != nil {
				k := make([]byte, len(key))
				copy(k, key)
				_ = f.pebble.Delete(k, pebble.NoSync)
				continue
			}
			var doc store.Job
			if err := decodeJobDoc(val, &doc); err != nil {
				closer.Close()
				k := make([]byte, len(key))
				copy(k, key)
				_ = f.pebble.Delete(k, pebble.NoSync)
				continue
			}
			closer.Close()
			if doc.State != store.StatePending {
				k := make([]byte, len(key))
				copy(k, key)
				_ = f.pebble.Delete(k, pebble.NoSync)
				continue
			}
			if !f.dependenciesSatisfied(doc) {
				continue
			}
			ak := make([]byte, len(key))
			copy(ak, key)
			return id, ak, doc, true
		}
	}

	return "", nil, store.Job{}, false
}

func (f *FSM) findPendingOrAppendJobForQueue(queue string, claimed map[string]struct{}) (jobID string, pendingKey []byte, appendKey []byte, job store.Job, ok bool) {
	if jobID, pendingKey, job, ok = f.findPendingJobForQueue(queue, claimed); ok {
		return jobID, pendingKey, nil, job, true
	}
	jobID, appendKey, job, ok = f.findAppendJobForQueue(queue, claimed)
	return jobID, nil, appendKey, job, ok
}

func (f *FSM) dependenciesSatisfied(job store.Job) bool {
	deps := chainDependsOn(job.ChainConfig)
	if len(deps) == 0 {
		return true
	}
	for _, depID := range deps {
		val, closer, err := f.pebble.Get(kv.JobKey(depID))
		if err != nil {
			return false
		}
		var dep store.Job
		if err := decodeJobDoc(val, &dep); err != nil {
			closer.Close()
			return false
		}
		closer.Close()
		if dep.State != store.StateCompleted {
			return false
		}
	}
	return true
}

func chainDependsOn(chainCfg json.RawMessage) []string {
	if len(chainCfg) == 0 {
		return nil
	}
	var doc map[string]any
	if err := json.Unmarshal(chainCfg, &doc); err != nil {
		return nil
	}
	raw, ok := doc["depends_on"]
	if !ok {
		return nil
	}
	list, ok := raw.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	seen := map[string]struct{}{}
	for _, item := range list {
		id, ok := item.(string)
		if !ok {
			continue
		}
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
}

// --- Ack ---

func (f *FSM) applyAck(data json.RawMessage) *store.OpResult {
	var op store.AckOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyAckOp(op)
}

func (f *FSM) applyAckOp(op store.AckOp) *store.OpResult {
	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %s not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %s: %w", op.JobID, err)}
	}
	closer.Close()

	if job.State != store.StateActive {
		return &store.OpResult{Err: fmt.Errorf("job %s is not active", op.JobID)}
	}

	if op.AgentStatus != "" && job.Agent == nil {
		return &store.OpResult{Err: fmt.Errorf("job %s is not an agent job", op.JobID)}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	now := time.Unix(0, int64(op.NowNs))
	nextState := store.StateCompleted
	iterationStatus := "done"
	iterationToRecord := 0
	if job.Agent != nil {
		iterationToRecord = job.Agent.Iteration
	}
	if op.AgentStatus != "" {
		iterationStatus = op.AgentStatus
	}

	if len(op.Checkpoint) > 0 {
		job.Checkpoint = op.Checkpoint
	}
	if op.Usage != nil && job.Agent != nil {
		job.Agent.TotalCostUSD += op.Usage.CostUSD
	}

	if job.Agent != nil {
		switch iterationStatus {
		case store.AgentStatusContinue:
			nextIteration := job.Agent.Iteration + 1
			guardrailReason := ""
			if job.Agent.MaxIterations > 0 && nextIteration > job.Agent.MaxIterations {
				guardrailReason = fmt.Sprintf("max_iterations exceeded (%d)", job.Agent.MaxIterations)
			}
			if guardrailReason == "" && job.Agent.MaxCostUSD > 0 && job.Agent.TotalCostUSD > job.Agent.MaxCostUSD {
				guardrailReason = fmt.Sprintf("max_cost_usd exceeded (%.4f > %.4f)", job.Agent.TotalCostUSD, job.Agent.MaxCostUSD)
			}
			job.Agent.Iteration = nextIteration
			if guardrailReason != "" {
				nextState = store.StateHeld
				iterationStatus = store.AgentStatusHold
				if op.HoldReason == "" {
					op.HoldReason = guardrailReason
				}
			} else {
				nextState = store.StatePending
			}
		case store.AgentStatusHold:
			nextState = store.StateHeld
		case "", store.AgentStatusDone:
			nextState = store.StateCompleted
			iterationStatus = store.AgentStatusDone
		default:
			return &store.OpResult{Err: fmt.Errorf("invalid agent_status %q", op.AgentStatus)}
		}
	}

	job.State = nextState
	job.ProviderError = false
	if len(op.Result) > 0 {
		job.Result = op.Result
	}
	if op.HoldReason != "" {
		job.HoldReason = &op.HoldReason
	} else if nextState != store.StateHeld {
		job.HoldReason = nil
	}

	if nextState == store.StateCompleted {
		job.CompletedAt = &now
	}
	job.WorkerID = nil
	job.Hostname = nil
	job.LeaseExpiresAt = nil

	jobData, _ := encodeJobDoc(job)
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
	batch.Delete(kv.ActiveKey(job.Queue, op.JobID), f.writeOpts)
	f.decrActive(job.Queue)

	if nextState == store.StatePending {
		createdNs := uint64(now.UnixNano())
		if job.Priority == store.PriorityNormal {
			batch.Set(kv.QueueAppendKey(job.Queue, createdNs, op.JobID), nil, f.writeOpts)
		} else {
			batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, op.JobID), nil, f.writeOpts)
		}
	}

	// Clean unique lock only on terminal completion.
	if nextState == store.StateCompleted && job.UniqueKey != nil {
		batch.Delete(kv.UniqueKey(job.Queue, *job.UniqueKey), f.writeOpts)
	}

	// Chain progression: advance to next step on completion.
	var chainNextJob *store.Job
	if nextState == store.StateCompleted && len(job.ChainConfig) > 0 {
		chainNextJob = f.progressChain(batch, job, op, now)
	}

	// Update batch counter
	var callbackJobID string
	if nextState == store.StateCompleted && job.BatchID != nil {
		callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "success", op.NowNs)
	}
	eventType := "completed"
	switch nextState {
	case store.StatePending:
		eventType = "continued"
	case store.StateHeld:
		eventType = "held"
	}
	if err := f.appendLifecycleEvent(batch, eventType, op.JobID, job.Queue, op.NowNs); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit ack: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		nowStr := now.UTC().Format(time.RFC3339Nano)
		iterationJob := job
		if iterationToRecord > 0 && iterationJob.Agent != nil {
			a := *iterationJob.Agent
			a.Iteration = iterationToRecord
			iterationJob.Agent = &a
		}
		if err := sqliteUpsertJobDoc(db, job); err != nil {
			return err
		}
		if nextState == store.StateCompleted && job.UniqueKey != nil {
			db.Exec("DELETE FROM unique_locks WHERE job_id = ?", op.JobID)
		}
		if nextState == store.StateCompleted && job.BatchID != nil {
			sqliteUpdateBatch(db, *job.BatchID, "success", callbackJobID)
		}
		if chainNextJob != nil {
			if err := sqliteUpsertJobDoc(db, *chainNextJob); err != nil {
				return err
			}
		}
		if err := sqliteInsertUsage(db, op.JobID, job.Queue, job.Attempt, "ack", op.Usage, nowStr); err != nil {
			return err
		}
		if err := sqliteInsertJobIteration(db, iterationJob, op, iterationStatus, nowStr); err != nil {
			return err
		}
		return nil
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applyAckBatch(data json.RawMessage) *store.OpResult {
	var op store.AckBatchOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyAckBatchOp(op)
}

func (f *FSM) applyAckBatchOp(op store.AckBatchOp) *store.OpResult {
	if len(op.Acks) == 0 {
		return &store.OpResult{Data: 0}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	now := time.Unix(0, int64(op.NowNs))
	type sqliteAck struct {
		job           store.Job
		ack           store.AckOp
		callbackJobID string
	}
	sqliteAcks := make([]sqliteAck, 0, len(op.Acks))
	acked := 0

	for _, ack := range op.Acks {
		if ack.JobID == "" {
			continue
		}
		jobVal, closer, err := f.pebble.Get(kv.JobKey(ack.JobID))
		if err != nil {
			continue
		}
		var job store.Job
		if err := decodeJobDoc(jobVal, &job); err != nil {
			closer.Close()
			continue
		}
		closer.Close()
		if job.State != store.StateActive {
			continue
		}

		job.State = store.StateCompleted
		job.ProviderError = false
		job.CompletedAt = &now
		if len(ack.Result) > 0 {
			job.Result = ack.Result
		}
		job.WorkerID = nil
		job.Hostname = nil
		job.LeaseExpiresAt = nil

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(ack.JobID), jobData, f.writeOpts)
		batch.Delete(kv.ActiveKey(job.Queue, ack.JobID), f.writeOpts)
		f.decrActive(job.Queue)
		if job.UniqueKey != nil {
			batch.Delete(kv.UniqueKey(job.Queue, *job.UniqueKey), f.writeOpts)
		}

		callbackJobID := ""
		if job.BatchID != nil {
			callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "success", op.NowNs)
		}
		if err := f.appendLifecycleEvent(batch, "completed", ack.JobID, job.Queue, op.NowNs); err != nil {
			return &store.OpResult{Err: err}
		}
		sqliteAcks = append(sqliteAcks, sqliteAck{
			job:           job,
			ack:           store.AckOp{JobID: ack.JobID, Result: ack.Result, NowNs: op.NowNs},
			callbackJobID: callbackJobID,
		})
		acked++
	}

	if acked == 0 {
		return &store.OpResult{Data: 0}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit ack batch: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		tx, ok := db.(*sql.DB)
		if !ok {
			for _, a := range sqliteAcks {
				if err := sqliteAckJob(db, a.job, a.ack, a.callbackJobID); err != nil {
					return err
				}
			}
			return nil
		}
		sqlTx, err := tx.Begin()
		if err != nil {
			return err
		}
		for _, a := range sqliteAcks {
			if err := sqliteAckJob(sqlTx, a.job, a.ack, a.callbackJobID); err != nil {
				_ = sqlTx.Rollback()
				return err
			}
		}
		return sqlTx.Commit()
	})

	return &store.OpResult{Data: acked}
}

// applyMultiAckBatch merges multiple AckBatch ops from a single raft.Apply
// into one Pebble batch commit, reducing write amplification under high
// concurrency.
func (f *FSM) applyMultiAckBatch(ops []*store.DecodedRaftOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))
	if len(ops) == 0 {
		return &store.OpResult{Data: results}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	type sqliteAck struct {
		job           store.Job
		ack           store.AckOp
		callbackJobID string
	}
	var allSqliteAcks []sqliteAck
	totalAcked := 0

	for i, sub := range ops {
		op := sub.AckBatch
		if op == nil || len(op.Acks) == 0 {
			results[i] = &store.OpResult{Data: 0}
			continue
		}
		now := time.Unix(0, int64(op.NowNs))
		acked := 0

		for _, ack := range op.Acks {
			if ack.JobID == "" {
				continue
			}
			jobVal, closer, err := f.pebble.Get(kv.JobKey(ack.JobID))
			if err != nil {
				continue
			}
			var job store.Job
			if err := decodeJobDoc(jobVal, &job); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if job.State != store.StateActive {
				continue
			}

			job.State = store.StateCompleted
			job.ProviderError = false
			job.CompletedAt = &now
			if len(ack.Result) > 0 {
				job.Result = ack.Result
			}
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil

			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(ack.JobID), jobData, f.writeOpts)
			batch.Delete(kv.ActiveKey(job.Queue, ack.JobID), f.writeOpts)
			f.decrActive(job.Queue)
			if job.UniqueKey != nil {
				batch.Delete(kv.UniqueKey(job.Queue, *job.UniqueKey), f.writeOpts)
			}

			callbackJobID := ""
			if job.BatchID != nil {
				callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "success", op.NowNs)
			}
			if err := f.appendLifecycleEvent(batch, "completed", ack.JobID, job.Queue, op.NowNs); err != nil {
				results[i] = &store.OpResult{Err: err}
				break
			}
			allSqliteAcks = append(allSqliteAcks, sqliteAck{
				job:           job,
				ack:           store.AckOp{JobID: ack.JobID, Result: ack.Result, NowNs: op.NowNs},
				callbackJobID: callbackJobID,
			})
			acked++
		}
		if results[i] == nil {
			results[i] = &store.OpResult{Data: acked}
		}
		totalAcked += acked
	}

	if totalAcked == 0 {
		return &store.OpResult{Data: results}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		errResult := &store.OpResult{Err: err}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		errResult := &store.OpResult{Err: fmt.Errorf("pebble commit multi ack batch: %w", err)}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	f.syncSQLite(func(db sqlExecer) error {
		tx, ok := db.(*sql.DB)
		if !ok {
			for _, a := range allSqliteAcks {
				if err := sqliteAckJob(db, a.job, a.ack, a.callbackJobID); err != nil {
					return err
				}
			}
			return nil
		}
		sqlTx, err := tx.Begin()
		if err != nil {
			return err
		}
		for _, a := range allSqliteAcks {
			if err := sqliteAckJob(sqlTx, a.job, a.ack, a.callbackJobID); err != nil {
				_ = sqlTx.Rollback()
				return err
			}
		}
		return sqlTx.Commit()
	})

	return &store.OpResult{Data: results}
}

// applyMultiFetchBatch merges multiple FetchBatch ops from a single raft.Apply
// into one Pebble batch commit, reducing write amplification under high
// concurrency. Each FetchBatch still gets its own result slice.
func (f *FSM) applyMultiFetchBatch(ops []*store.DecodedRaftOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))
	if len(ops) == 0 {
		return &store.OpResult{Data: results}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	type sqliteFetch struct {
		jobs []store.Job
		op   store.FetchBatchOp
	}
	var allSqliteFetches []sqliteFetch
	totalFetched := 0

	// Global claimed set prevents two FetchBatch ops from claiming the same job.
	claimed := make(map[string]struct{})

	for i, sub := range ops {
		op := sub.FetchBatch
		if op == nil || len(op.Queues) == 0 || op.Count <= 0 {
			results[i] = &store.OpResult{Data: []store.FetchResult{}}
			continue
		}

		nowNs := op.NowNs
		leaseDuration := op.LeaseDuration
		if leaseDuration <= 0 {
			leaseDuration = 60
		}
		leaseExpiresNs := nowNs + uint64(leaseDuration)*1_000_000_000

		startedAt := time.Unix(0, int64(nowNs))
		leaseExp := time.Unix(0, int64(leaseExpiresNs))
		worker := store.Worker{
			ID:            op.WorkerID,
			Queues:        marshalStringSlice(op.Queues),
			LastHeartbeat: startedAt,
			StartedAt:     startedAt,
		}
		if op.Hostname != "" {
			worker.Hostname = &op.Hostname
		}
		workerData, _ := json.Marshal(worker)
		batch.Set(kv.WorkerKey(op.WorkerID), workerData, f.writeOpts)

		type queueState struct {
			name        string
			activeLimit int
			activeCount int
			rateLimit   int
			rateCount   int
		}

		states := make([]queueState, 0, len(op.Queues))
		for _, queue := range op.Queues {
			qs := queueState{name: queue}
			qcKey := kv.QueueConfigKey(queue)
			if qcVal, closer, err := f.pebble.Get(qcKey); err == nil {
				var qc store.Queue
				if err := json.Unmarshal(qcVal, &qc); err != nil {
					closer.Close()
					continue
				}
				closer.Close()
				if qc.Paused {
					continue
				}
				if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
					qs.activeLimit = *qc.MaxConcurrency
					qs.activeCount = f.getActiveCount(queue)
				}
				if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
					qs.rateLimit = *qc.RateLimit
					windowNs := uint64(*qc.RateWindowMs) * 1_000_000
					windowStart := nowNs - windowNs
					qs.rateCount = countPrefixFrom(f.pebble, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
				}
			}
			states = append(states, qs)
		}

		fetchResults := make([]store.FetchResult, 0, op.Count)
		sqliteJobs := make([]store.Job, 0, op.Count)
		rateSeq := uint64(0)

		// Pre-resolved path: iterate candidates with O(1) lookups.
		if len(op.CandidateJobIDs) > 0 {
			stateMap := make(map[string]*queueState, len(states))
			for qi := range states {
				stateMap[states[qi].name] = &states[qi]
			}
			for ci, jobID := range op.CandidateJobIDs {
				if len(fetchResults) >= op.Count {
					break
				}
				queue := op.CandidateQueues[ci]
				qs := stateMap[queue]
				if qs == nil {
					continue
				}
				if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
					continue
				}
				if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
					continue
				}
				if _, exists := claimed[jobID]; exists {
					continue
				}
				val, closer, err := f.pebble.Get(kv.JobKey(jobID))
				if err != nil {
					continue
				}
				var job store.Job
				if err := decodeJobDoc(val, &job); err != nil {
					closer.Close()
					continue
				}
				closer.Close()
				if job.State != store.StatePending {
					continue
				}
				if !f.dependenciesSatisfied(job) {
					continue
				}
				claimed[jobID] = struct{}{}
				job.State = store.StateActive
				job.WorkerID = &op.WorkerID
				job.Hostname = &op.Hostname
				job.Attempt++
				job.StartedAt = &startedAt
				job.LeaseExpiresAt = &leaseExp
				jobData, _ := encodeJobDoc(job)
				batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
				createdNs := uint64(job.CreatedAt.UnixNano())
				if job.Priority == store.PriorityNormal {
					appendKey := kv.QueueAppendKey(queue, createdNs, jobID)
					batch.Delete(appendKey, f.writeOpts)
					batch.Set(kv.QueueCursorKey(queue), appendKey, f.writeOpts)
				} else {
					pendingKey := kv.PendingKey(queue, uint8(job.Priority), createdNs, jobID)
					batch.Delete(pendingKey, f.writeOpts)
				}
				batch.Set(kv.ActiveKey(queue, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
				f.incrActive(queue)
				if qs.rateLimit > 0 {
					batch.Set(kv.RateLimitKey(queue, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
					rateSeq++
					qs.rateCount++
				}
				if err := f.appendLifecycleEvent(batch, "started", jobID, queue, nowNs); err != nil {
					results[i] = &store.OpResult{Err: err}
					break
				}
				if qs.activeLimit > 0 {
					qs.activeCount++
				}
				sqliteJobs = append(sqliteJobs, job)
				fetchResults = append(fetchResults, store.FetchResult{
					JobID:         jobID,
					Queue:         queue,
					Payload:       job.Payload,
					Attempt:       job.Attempt,
					MaxRetries:    job.MaxRetries,
					LeaseDuration: leaseDuration,
					Tags:          job.Tags,
					Checkpoint:    job.Checkpoint,
					Agent:         job.Agent,
				})
			}
			goto multiFetchDone
		}

		for len(fetchResults) < op.Count {
			progress := false
			for qi := range states {
				qs := &states[qi]
				if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
					continue
				}
				if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
					continue
				}
				jobID, pendingKey, appendKey, job, ok := f.findPendingOrAppendJobForQueue(qs.name, claimed)
				if !ok {
					continue
				}
				progress = true
				claimed[jobID] = struct{}{}

				job.State = store.StateActive
				job.WorkerID = &op.WorkerID
				job.Hostname = &op.Hostname
				job.Attempt++
				job.StartedAt = &startedAt
				job.LeaseExpiresAt = &leaseExp

				jobData, _ := encodeJobDoc(job)
				batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
				if len(pendingKey) > 0 {
					batch.Delete(pendingKey, f.writeOpts)
				}
				if len(appendKey) > 0 {
					batch.Delete(appendKey, f.writeOpts)
					batch.Set(kv.QueueCursorKey(qs.name), appendKey, f.writeOpts)
				}
				batch.Set(kv.ActiveKey(qs.name, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
				f.incrActive(qs.name)
				if qs.rateLimit > 0 {
					batch.Set(kv.RateLimitKey(qs.name, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
					rateSeq++
					qs.rateCount++
				}
				if err := f.appendLifecycleEvent(batch, "started", jobID, qs.name, nowNs); err != nil {
					results[i] = &store.OpResult{Err: err}
					break
				}
				if qs.activeLimit > 0 {
					qs.activeCount++
				}
				sqliteJobs = append(sqliteJobs, job)
				fetchResults = append(fetchResults, store.FetchResult{
					JobID:         jobID,
					Queue:         qs.name,
					Payload:       job.Payload,
					Attempt:       job.Attempt,
					MaxRetries:    job.MaxRetries,
					LeaseDuration: leaseDuration,
					Tags:          job.Tags,
					Checkpoint:    job.Checkpoint,
					Agent:         job.Agent,
				})
				if len(fetchResults) >= op.Count {
					break
				}
			}
			if !progress {
				break
			}
		}

	multiFetchDone:
		if results[i] == nil {
			results[i] = &store.OpResult{Data: fetchResults}
		}
		if len(sqliteJobs) > 0 {
			allSqliteFetches = append(allSqliteFetches, sqliteFetch{
				jobs: sqliteJobs,
				op:   *op,
			})
		}
		totalFetched += len(fetchResults)
	}

	if totalFetched == 0 {
		return &store.OpResult{Data: results}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		errResult := &store.OpResult{Err: err}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		errResult := &store.OpResult{Err: fmt.Errorf("pebble commit multi fetch batch: %w", err)}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	f.syncSQLite(func(db sqlExecer) error {
		for _, sf := range allSqliteFetches {
			for _, job := range sf.jobs {
				if err := sqliteFetchJob(db, job, store.FetchOp{
					Queues:        sf.op.Queues,
					WorkerID:      sf.op.WorkerID,
					Hostname:      sf.op.Hostname,
					LeaseDuration: sf.op.LeaseDuration,
					NowNs:         sf.op.NowNs,
					RandomSeed:    sf.op.RandomSeed,
				}); err != nil {
					return err
				}
			}
		}
		return nil
	})

	return &store.OpResult{Data: results}
}

// applyAckBatchIntoBatch processes a single AckBatch op into a shared Pebble
// batch (indexed mode). Reads go through the batch to see prior writes.
// The caller is responsible for batch.Commit() and lifecycle cursor.
func (f *FSM) applyAckBatchIntoBatch(batch *pebble.Batch, op store.AckBatchOp, sqliteCbs *[]func(db sqlExecer) error) *store.OpResult {
	if len(op.Acks) == 0 {
		return &store.OpResult{Data: 0}
	}
	now := time.Unix(0, int64(op.NowNs))
	acked := 0

	type sqliteAck struct {
		job           store.Job
		ack           store.AckOp
		callbackJobID string
	}
	var sqliteAcks []sqliteAck

	for _, ack := range op.Acks {
		if ack.JobID == "" {
			continue
		}
		// Read from batch (indexed) to see writes from earlier ops.
		jobVal, closer, err := batch.Get(kv.JobKey(ack.JobID))
		if err != nil {
			continue
		}
		var job store.Job
		if err := decodeJobDoc(jobVal, &job); err != nil {
			closer.Close()
			continue
		}
		closer.Close()
		if job.State != store.StateActive {
			continue
		}

		job.State = store.StateCompleted
		job.ProviderError = false
		job.CompletedAt = &now
		if len(ack.Result) > 0 {
			job.Result = ack.Result
		}
		job.WorkerID = nil
		job.Hostname = nil
		job.LeaseExpiresAt = nil

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(ack.JobID), jobData, f.writeOpts)
		batch.Delete(kv.ActiveKey(job.Queue, ack.JobID), f.writeOpts)
		f.decrActive(job.Queue)
		if job.UniqueKey != nil {
			batch.Delete(kv.UniqueKey(job.Queue, *job.UniqueKey), f.writeOpts)
		}
		callbackJobID := ""
		if job.BatchID != nil {
			callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "success", op.NowNs)
		}
		if err := f.appendLifecycleEvent(batch, "completed", ack.JobID, job.Queue, op.NowNs); err != nil {
			return &store.OpResult{Err: err}
		}
		sqliteAcks = append(sqliteAcks, sqliteAck{job: job, ack: store.AckOp{JobID: ack.JobID, Result: ack.Result, NowNs: op.NowNs}, callbackJobID: callbackJobID})
		acked++
	}

	if len(sqliteAcks) > 0 {
		*sqliteCbs = append(*sqliteCbs, func(db sqlExecer) error {
			for _, a := range sqliteAcks {
				if err := sqliteAckJob(db, a.job, a.ack, a.callbackJobID); err != nil {
					return err
				}
			}
			return nil
		})
	}

	return &store.OpResult{Data: acked}
}

// applyFetchBatchIntoBatch processes a single FetchBatch op into a shared Pebble
// batch (indexed mode). Uses the batch for reads to see writes from prior ops
// (e.g., acks that freed active slots). The claimed map prevents double-fetching
// across multiple FetchBatch ops in the same indexed batch.
func (f *FSM) applyFetchBatchIntoBatch(batch *pebble.Batch, op store.FetchBatchOp, claimed map[string]struct{}, seenWorkers map[string]struct{}, sqliteCbs *[]func(db sqlExecer) error) *store.OpResult {
	if len(op.Queues) == 0 || op.Count <= 0 {
		return &store.OpResult{Data: []store.FetchResult{}}
	}

	nowNs := op.NowNs
	leaseDuration := op.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}
	leaseExpiresNs := nowNs + uint64(leaseDuration)*1_000_000_000

	startedAt := time.Unix(0, int64(nowNs))
	leaseExp := time.Unix(0, int64(leaseExpiresNs))
	worker := store.Worker{
		ID:            op.WorkerID,
		Queues:        marshalStringSlice(op.Queues),
		LastHeartbeat: startedAt,
		StartedAt:     startedAt,
	}
	if op.Hostname != "" {
		worker.Hostname = &op.Hostname
	}
	// Skip redundant worker writes within the same indexed batch.
	if _, already := seenWorkers[op.WorkerID]; !already {
		workerData, _ := json.Marshal(worker)
		batch.Set(kv.WorkerKey(op.WorkerID), workerData, f.writeOpts)
		seenWorkers[op.WorkerID] = struct{}{}
	}

	type queueState struct {
		name        string
		activeLimit int
		activeCount int
		rateLimit   int
		rateCount   int
	}

	states := make([]queueState, 0, len(op.Queues))
	for _, queue := range op.Queues {
		qs := queueState{name: queue}
		qcKey := kv.QueueConfigKey(queue)
		// Read queue config from batch to see any prior writes.
		if qcVal, closer, err := batch.Get(qcKey); err == nil {
			var qc store.Queue
			if err := json.Unmarshal(qcVal, &qc); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if qc.Paused {
				continue
			}
			if qc.MaxConcurrency != nil && *qc.MaxConcurrency > 0 {
				qs.activeLimit = *qc.MaxConcurrency
				qs.activeCount = f.getActiveCount(queue)
			}
			if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
				qs.rateLimit = *qc.RateLimit
				windowNs := uint64(*qc.RateWindowMs) * 1_000_000
				windowStart := nowNs - windowNs
				qs.rateCount = countPrefixFromReader(batch, kv.RateLimitPrefix(queue), kv.RateLimitWindowStart(queue, windowStart))
			}
		}
		states = append(states, qs)
	}

	results := make([]store.FetchResult, 0, op.Count)
	var sqliteJobs []store.Job
	rateSeq := uint64(0)

	// Pre-resolved path: O(1) point lookups from batch (sees prior writes).
	if len(op.CandidateJobIDs) > 0 {
		stateMap := make(map[string]*queueState, len(states))
		for qi := range states {
			stateMap[states[qi].name] = &states[qi]
		}
		for ci, jobID := range op.CandidateJobIDs {
			if len(results) >= op.Count {
				break
			}
			queue := op.CandidateQueues[ci]
			qs := stateMap[queue]
			if qs == nil {
				continue
			}
			if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
				continue
			}
			if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
				continue
			}
			if _, exists := claimed[jobID]; exists {
				continue
			}
			val, closer, err := batch.Get(kv.JobKey(jobID))
			if err != nil {
				continue
			}
			var job store.Job
			if err := decodeJobDoc(val, &job); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if job.State != store.StatePending {
				continue
			}
			if !f.dependenciesSatisfied(job) {
				continue
			}
			claimed[jobID] = struct{}{}
			job.State = store.StateActive
			job.WorkerID = &op.WorkerID
			job.Hostname = &op.Hostname
			job.Attempt++
			job.StartedAt = &startedAt
			job.LeaseExpiresAt = &leaseExp
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			createdNs := uint64(job.CreatedAt.UnixNano())
			if job.Priority == store.PriorityNormal {
				appendKey := kv.QueueAppendKey(queue, createdNs, jobID)
				batch.Delete(appendKey, f.writeOpts)
				batch.Set(kv.QueueCursorKey(queue), appendKey, f.writeOpts)
			} else {
				pendingKey := kv.PendingKey(queue, uint8(job.Priority), createdNs, jobID)
				batch.Delete(pendingKey, f.writeOpts)
			}
			batch.Set(kv.ActiveKey(queue, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
			f.incrActive(queue)
			if qs.rateLimit > 0 {
				batch.Set(kv.RateLimitKey(queue, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
				rateSeq++
				qs.rateCount++
			}
			if err := f.appendLifecycleEvent(batch, "started", jobID, queue, nowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			if qs.activeLimit > 0 {
				qs.activeCount++
			}
			sqliteJobs = append(sqliteJobs, job)
			results = append(results, store.FetchResult{
				JobID:         jobID,
				Queue:         queue,
				Payload:       job.Payload,
				Attempt:       job.Attempt,
				MaxRetries:    job.MaxRetries,
				LeaseDuration: leaseDuration,
				Tags:          job.Tags,
				Checkpoint:    job.Checkpoint,
				Agent:         job.Agent,
			})
		}
		goto indexedFetchDone
	}

	for len(results) < op.Count {
		progress := false
		for qi := range states {
			qs := &states[qi]
			if qs.activeLimit > 0 && qs.activeCount >= qs.activeLimit {
				continue
			}
			if qs.rateLimit > 0 && qs.rateCount >= qs.rateLimit {
				continue
			}
			// Read from batch to see prior writes (e.g., pending keys deleted
			// by earlier fetch ops in this indexed batch).
			jobID, pendingKey, appendKey, job, ok := findPendingOrAppendJobFromReader(batch, qs.name, claimed)
			if !ok {
				continue
			}
			progress = true
			claimed[jobID] = struct{}{}

			job.State = store.StateActive
			job.WorkerID = &op.WorkerID
			job.Hostname = &op.Hostname
			job.Attempt++
			job.StartedAt = &startedAt
			job.LeaseExpiresAt = &leaseExp

			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if len(pendingKey) > 0 {
				batch.Delete(pendingKey, f.writeOpts)
			}
			if len(appendKey) > 0 {
				batch.Delete(appendKey, f.writeOpts)
				batch.Set(kv.QueueCursorKey(qs.name), appendKey, f.writeOpts)
			}
			batch.Set(kv.ActiveKey(qs.name, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)
			f.incrActive(qs.name)
			if qs.rateLimit > 0 {
				batch.Set(kv.RateLimitKey(qs.name, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
				rateSeq++
				qs.rateCount++
			}
			if err := f.appendLifecycleEvent(batch, "started", jobID, qs.name, nowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			if qs.activeLimit > 0 {
				qs.activeCount++
			}
			sqliteJobs = append(sqliteJobs, job)
			results = append(results, store.FetchResult{
				JobID:         jobID,
				Queue:         qs.name,
				Payload:       job.Payload,
				Attempt:       job.Attempt,
				MaxRetries:    job.MaxRetries,
				LeaseDuration: leaseDuration,
				Tags:          job.Tags,
				Checkpoint:    job.Checkpoint,
				Agent:         job.Agent,
			})
			if len(results) >= op.Count {
				break
			}
		}
		if !progress {
			break
		}
	}
indexedFetchDone:

	if len(sqliteJobs) > 0 {
		opCopy := op
		*sqliteCbs = append(*sqliteCbs, func(db sqlExecer) error {
			for _, job := range sqliteJobs {
				if err := sqliteFetchJob(db, job, store.FetchOp{
					Queues:        opCopy.Queues,
					WorkerID:      opCopy.WorkerID,
					Hostname:      opCopy.Hostname,
					LeaseDuration: opCopy.LeaseDuration,
					NowNs:         opCopy.NowNs,
					RandomSeed:    opCopy.RandomSeed,
				}); err != nil {
					return err
				}
			}
			return nil
		})
	}

	return &store.OpResult{Data: results}
}

// findPendingOrAppendJobFromReader is like findPendingOrAppendJobForQueue but
// reads from a pebble.Reader (which can be an indexed batch) instead of f.pebble.
func findPendingOrAppendJobFromReader(r pebble.Reader, queue string, claimed map[string]struct{}) (jobID string, pendingKey []byte, appendKey []byte, job store.Job, ok bool) {
	if jobID, pendingKey, job, ok = findPendingJobFromReader(r, queue, claimed); ok {
		return jobID, pendingKey, nil, job, true
	}
	jobID, appendKey, job, ok = findAppendJobFromReader(r, queue, claimed)
	return jobID, nil, appendKey, job, ok
}

func findPendingJobFromReader(r pebble.Reader, queue string, claimed map[string]struct{}) (jobID string, pendingKey []byte, job store.Job, ok bool) {
	prefix := kv.PendingPrefix(queue)
	iter, err := r.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return "", nil, store.Job{}, false
	}
	defer iter.Close()

	for valid := iter.First(); valid; valid = iter.Next() {
		key := iter.Key()
		idOffset := len(prefix) + 1 + 8
		if len(key) <= idOffset {
			continue
		}
		id := string(key[idOffset:])
		if _, exists := claimed[id]; exists {
			continue
		}
		val, closer, err := r.Get(kv.JobKey(id))
		if err != nil {
			continue
		}
		var doc store.Job
		if err := decodeJobDoc(val, &doc); err != nil {
			closer.Close()
			continue
		}
		closer.Close()
		if doc.State != store.StatePending {
			continue
		}
		pk := make([]byte, len(key))
		copy(pk, key)
		return id, pk, doc, true
	}
	return "", nil, store.Job{}, false
}

func findAppendJobFromReader(r pebble.Reader, queue string, claimed map[string]struct{}) (jobID string, appendKey []byte, job store.Job, ok bool) {
	prefix := kv.QueueAppendPrefix(queue)
	var lower []byte
	if cursor, closer, err := r.Get(kv.QueueCursorKey(queue)); err == nil {
		lower = append([]byte(nil), cursor...)
		closer.Close()
	}

	iter, err := r.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return "", nil, store.Job{}, false
	}
	defer iter.Close()

	var valid bool
	hasCursor := len(lower) > 0
	if hasCursor {
		valid = iter.SeekGE(lower)
		if valid && bytes.Equal(iter.Key(), lower) {
			valid = iter.Next()
		}
	} else {
		valid = iter.First()
	}

	for ; valid; valid = iter.Next() {
		key := iter.Key()
		idOffset := len(prefix) + 8
		if len(key) <= idOffset {
			continue
		}
		id := string(key[idOffset:])
		if _, exists := claimed[id]; exists {
			continue
		}
		val, closer, err := r.Get(kv.JobKey(id))
		if err != nil {
			continue
		}
		var doc store.Job
		if err := decodeJobDoc(val, &doc); err != nil {
			closer.Close()
			continue
		}
		closer.Close()
		if doc.State != store.StatePending {
			continue
		}
		ak := make([]byte, len(key))
		copy(ak, key)
		return id, ak, doc, true
	}

	// Cursor-based scan found nothing. Rescan before the cursor for
	// entries with timestamps before the cursor position.
	// Note: stale append keys (non-pending jobs) are not deleted here because
	// this function operates on a pebble.Reader (read-only interface, used in
	// applyMultiIndexed's IndexedBatch path). Cleanup of stale keys happens in
	// findAppendJobForQueue, which has direct *pebble.DB write access.
	if hasCursor {
		iter2, err := r.NewIter(&pebble.IterOptions{
			LowerBound: prefix,
			UpperBound: lower,
		})
		if err != nil {
			return "", nil, store.Job{}, false
		}
		defer iter2.Close()

		for valid := iter2.First(); valid; valid = iter2.Next() {
			key := iter2.Key()
			idOffset := len(prefix) + 8
			if len(key) <= idOffset {
				continue
			}
			id := string(key[idOffset:])
			if _, exists := claimed[id]; exists {
				continue
			}
			val, closer, err := r.Get(kv.JobKey(id))
			if err != nil {
				continue
			}
			var doc store.Job
			if err := decodeJobDoc(val, &doc); err != nil {
				closer.Close()
				continue
			}
			closer.Close()
			if doc.State != store.StatePending {
				continue
			}
			ak := make([]byte, len(key))
			copy(ak, key)
			return id, ak, doc, true
		}
	}

	return "", nil, store.Job{}, false
}

// countPrefixFromReader is like countPrefixFrom but reads from a pebble.Reader.
func countPrefixFromReader(r pebble.Reader, prefix, startKey []byte) int {
	iter, err := r.NewIter(&pebble.IterOptions{
		LowerBound: startKey,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return 0
	}
	defer iter.Close()
	count := 0
	for iter.First(); iter.Valid(); iter.Next() {
		count++
	}
	return count
}

// --- Fail ---

func (f *FSM) applyFail(data json.RawMessage) *store.OpResult {
	var op store.FailOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyFailOp(op)
}

func (f *FSM) applyFailOp(op store.FailOp) *store.OpResult {

	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %s not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %s: %w", op.JobID, err)}
	}
	closer.Close()

	if job.State != store.StateActive {
		return &store.OpResult{Err: fmt.Errorf("job %s is not active (state=%s)", op.JobID, job.State)}
	}

	now := time.Unix(0, int64(op.NowNs))
	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Write error record
	errDoc := store.JobError{
		JobID:     op.JobID,
		Attempt:   job.Attempt,
		Error:     op.Error,
		CreatedAt: now,
	}
	if op.Backtrace != "" {
		errDoc.Backtrace = &op.Backtrace
	}
	errData, _ := json.Marshal(errDoc)
	batch.Set(kv.JobErrorKey(op.JobID, uint32(job.Attempt)), errData, f.writeOpts)

	// Remove from active set
	batch.Delete(kv.ActiveKey(job.Queue, op.JobID), f.writeOpts)
	f.decrActive(job.Queue)
	if err := f.appendLifecycleEvent(batch, "failed", op.JobID, job.Queue, op.NowNs); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	remaining := job.MaxRetries - job.Attempt
	if remaining < 0 {
		remaining = 0
	}

	var result store.FailResult
	var callbackJobID string

	if remaining > 0 {
		delay := store.CalculateBackoff(job.RetryBackoff, job.Attempt, job.RetryBaseDelay, job.RetryMaxDelay)
		nextAttempt := now.Add(delay)
		retryNs := uint64(nextAttempt.UnixNano())

		job.State = store.StateRetrying
		job.FailedAt = &now
		job.ScheduledAt = &nextAttempt
		job.ProviderError = op.ProviderError
		job.WorkerID = nil
		job.Hostname = nil
		job.LeaseExpiresAt = nil

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
		batch.Set(kv.RetryingKey(job.Queue, retryNs, op.JobID), nil, f.writeOpts)

		result.Status = store.StateRetrying
		result.NextAttemptAt = &nextAttempt
		result.AttemptsRemaining = remaining
	} else {
		job.State = store.StateDead
		job.FailedAt = &now
		job.ProviderError = op.ProviderError
		job.WorkerID = nil
		job.Hostname = nil
		job.LeaseExpiresAt = nil

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)

		result.Status = store.StateDead
		result.AttemptsRemaining = 0

		if job.BatchID != nil {
			callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "failure", op.NowNs)
		}
	}

	// Chain failure: spawn on_failure handler when job goes dead.
	var chainFailJob *store.Job
	if job.State == store.StateDead && len(job.ChainConfig) > 0 {
		chainFailJob = f.progressChainFailure(batch, job, op, time.Unix(0, int64(op.NowNs)))
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit fail: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		if err := sqliteFailJob(db, job, op, errDoc, callbackJobID); err != nil {
			return err
		}
		if chainFailJob != nil {
			return sqliteUpsertJobDoc(db, *chainFailJob)
		}
		return nil
	})

	return &store.OpResult{Data: &result}
}

// --- Chain progression ---

// progressChain advances a chain to the next step or runs the on_exit handler.
// It writes the new job into the pebble batch and returns the job for SQLite sync.
func (f *FSM) progressChain(batch *pebble.Batch, job store.Job, op store.AckOp, now time.Time) *store.Job {
	if job.ChainStep == nil {
		return nil
	}
	currentStep := *job.ChainStep
	// Guard: negative steps are exit/failure handlers — don't recurse.
	if currentStep < 0 {
		return nil
	}

	var chain store.ChainDefinition
	if err := json.Unmarshal(job.ChainConfig, &chain); err != nil {
		return nil
	}

	stepStatus := op.StepStatus
	if stepStatus == "" {
		stepStatus = store.StepStatusContinue
	}

	var nextStep *store.ChainStep
	var nextStepIndex int

	switch stepStatus {
	case store.StepStatusContinue:
		nextIdx := currentStep + 1
		if nextIdx < len(chain.Steps) {
			nextStep = &chain.Steps[nextIdx]
			nextStepIndex = nextIdx
		} else {
			// Last step completed — run on_exit if configured.
			if chain.OnExit != nil {
				nextStep = chain.OnExit
				nextStepIndex = -1 // on_exit sentinel
			}
		}
	case store.StepStatusExit:
		if chain.OnExit != nil {
			nextStep = chain.OnExit
			nextStepIndex = -1 // on_exit sentinel
		}
	}

	if nextStep == nil {
		return nil
	}

	return f.enqueueChainStep(batch, job, nextStep, nextStepIndex, op.Result, now)
}

// progressChainFailure spawns the on_failure handler when a chain job goes dead.
func (f *FSM) progressChainFailure(batch *pebble.Batch, job store.Job, op store.FailOp, now time.Time) *store.Job {
	if job.ChainStep == nil {
		return nil
	}
	currentStep := *job.ChainStep
	// Guard: negative steps are exit/failure handlers — don't recurse.
	if currentStep < 0 {
		return nil
	}

	var chain store.ChainDefinition
	if err := json.Unmarshal(job.ChainConfig, &chain); err != nil {
		return nil
	}
	if chain.OnFailure == nil {
		return nil
	}

	// Build failure payload.
	failPayload := map[string]any{
		"failed_job_id": op.JobID,
		"failed_step":   currentStep,
		"error":         op.Error,
	}
	if len(chain.OnFailure.Payload) > 0 {
		var stepPayload map[string]any
		if err := json.Unmarshal(chain.OnFailure.Payload, &stepPayload); err == nil {
			for k, v := range stepPayload {
				failPayload[k] = v
			}
		}
	}

	payloadBytes, _ := json.Marshal(failPayload)
	newJob := f.createChainJob(batch, job, chain.OnFailure.Queue, payloadBytes, -2, now)
	return &newJob
}

// enqueueChainStep creates the next chain job with forwarded result payload.
func (f *FSM) enqueueChainStep(batch *pebble.Batch, prevJob store.Job, step *store.ChainStep, stepIndex int, prevResult json.RawMessage, now time.Time) *store.Job {
	payload := map[string]any{
		"previous_job_id": prevJob.ID,
	}
	if len(prevResult) > 0 {
		payload["previous_result"] = json.RawMessage(prevResult)
	}
	// Merge step-specific payload.
	if len(step.Payload) > 0 {
		var stepPayload map[string]any
		if err := json.Unmarshal(step.Payload, &stepPayload); err == nil {
			for k, v := range stepPayload {
				payload[k] = v
			}
		}
	}

	payloadBytes, _ := json.Marshal(payload)
	newJob := f.createChainJob(batch, prevJob, step.Queue, payloadBytes, stepIndex, now)
	return &newJob
}

// createChainJob builds a new pending job for chain progression and writes it to the pebble batch.
func (f *FSM) createChainJob(batch *pebble.Batch, prevJob store.Job, queue string, payload json.RawMessage, stepIndex int, now time.Time) store.Job {
	jobID := store.NewJobID()
	newJob := store.Job{
		ID:           jobID,
		Queue:        queue,
		State:        store.StatePending,
		Payload:      payload,
		Priority:     store.PriorityNormal,
		MaxRetries:   3,
		RetryBackoff: store.BackoffExponential,
		RetryBaseDelay: 5000,
		RetryMaxDelay:  600000,
		CreatedAt:    now.UTC(),
		ChainConfig:  prevJob.ChainConfig,
	}
	if prevJob.ChainID != nil {
		newJob.ChainID = prevJob.ChainID
	}
	newJob.ChainStep = &stepIndex

	jobData, _ := encodeJobDoc(newJob)
	batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
	batch.Set(kv.QueueNameKey(queue), nil, f.writeOpts)
	createdNs := uint64(now.UnixNano())
	batch.Set(kv.QueueAppendKey(queue, createdNs, jobID), nil, f.writeOpts)

	return newJob
}

// --- Heartbeat ---

func (f *FSM) applyHeartbeat(data json.RawMessage) *store.OpResult {
	var op store.HeartbeatOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyHeartbeatOp(op)
}

func (f *FSM) applyHeartbeatOp(op store.HeartbeatOp) *store.OpResult {
	now := time.Unix(0, int64(op.NowNs))
	leaseExpiresNs := op.NowNs + 60*1_000_000_000
	leaseExp := time.Unix(0, int64(leaseExpiresNs))

	resp := &store.HeartbeatResponse{
		Jobs: make(map[string]store.HeartbeatJobResponse, len(op.Jobs)),
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	var firstWorkerID string
	for jobID, update := range op.Jobs {
		jobVal, closer, err := f.pebble.Get(kv.JobKey(jobID))
		if err != nil {
			resp.Jobs[jobID] = store.HeartbeatJobResponse{Status: "cancel"}
			continue
		}
		var job store.Job
		if err := decodeJobDoc(jobVal, &job); err != nil {
			closer.Close()
			resp.Jobs[jobID] = store.HeartbeatJobResponse{Status: "cancel"}
			continue
		}
		closer.Close()

		if job.State != store.StateActive {
			resp.Jobs[jobID] = store.HeartbeatJobResponse{Status: "cancel"}
			continue
		}

		if firstWorkerID == "" && job.WorkerID != nil {
			firstWorkerID = *job.WorkerID
		}

		job.LeaseExpiresAt = &leaseExp
		if len(update.Progress) > 0 {
			job.Progress = update.Progress
		}
		if len(update.Checkpoint) > 0 {
			job.Checkpoint = update.Checkpoint
		}

		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
		// Update active key with new lease
		batch.Set(kv.ActiveKey(job.Queue, jobID), kv.PutUint64BE(nil, leaseExpiresNs), f.writeOpts)

		resp.Jobs[jobID] = store.HeartbeatJobResponse{Status: "ok"}
	}

	// Update worker heartbeat
	if firstWorkerID != "" {
		if wVal, wCloser, err := f.pebble.Get(kv.WorkerKey(firstWorkerID)); err == nil {
			var w store.Worker
			if err := json.Unmarshal(wVal, &w); err != nil {
				wCloser.Close()
			} else {
				wCloser.Close()
				w.LastHeartbeat = now
				wData, _ := json.Marshal(w)
				batch.Set(kv.WorkerKey(firstWorkerID), wData, f.writeOpts)
			}
		}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit heartbeat: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteHeartbeat(db, op, leaseExp, firstWorkerID, now)
	})

	return &store.OpResult{Data: resp}
}

// --- RetryJob ---

func (f *FSM) applyRetryJob(data json.RawMessage) *store.OpResult {
	var op store.RetryJobOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyRetryJobOp(op)
}

func (f *FSM) applyRetryJobOp(op store.RetryJobOp) *store.OpResult {
	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %q not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %q: %w", op.JobID, err)}
	}
	closer.Close()

	if job.State != store.StateDead && job.State != store.StateCancelled && job.State != store.StateCompleted && job.State != store.StateScheduled {
		return &store.OpResult{Err: fmt.Errorf("job %q cannot be retried from state %q", op.JobID, job.State)}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Remove from previous sorted set (e.g. scheduled key).
	f.removeFromSortedSet(batch, job)

	now := time.Unix(0, int64(op.NowNs))
	createdNs := uint64(now.UnixNano())

	job.State = store.StatePending
	job.ProviderError = false
	job.Attempt = 0
	job.FailedAt = nil
	job.CompletedAt = nil
	job.WorkerID = nil
	job.Hostname = nil
	job.LeaseExpiresAt = nil
	job.ScheduledAt = nil

	jobData, _ := encodeJobDoc(job)
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
	if job.Priority == store.PriorityNormal {
		batch.Set(kv.QueueAppendKey(job.Queue, createdNs, op.JobID), nil, f.writeOpts)
	} else {
		batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, op.JobID), nil, f.writeOpts)
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit retry: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteRetryJob(db, op.JobID)
	})

	return &store.OpResult{Data: nil}
}

// --- CancelJob ---

func (f *FSM) applyCancelJob(data json.RawMessage) *store.OpResult {
	var op store.CancelJobOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyCancelJobOp(op)
}

func (f *FSM) applyCancelJobOp(op store.CancelJobOp) *store.OpResult {
	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %q not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %q: %w", op.JobID, err)}
	}
	closer.Close()

	batch := f.pebble.NewBatch()
	defer batch.Close()

	var resultStatus string
	switch job.State {
	case store.StatePending:
		deletePendingOrAppendKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
		resultStatus = store.StateCancelled
	case store.StateScheduled:
		deleteScheduledKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
		resultStatus = store.StateCancelled
	case store.StateRetrying:
		deleteRetryingKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
		resultStatus = store.StateCancelled
	case store.StateActive:
		batch.Delete(kv.ActiveKey(job.Queue, op.JobID), f.writeOpts)
		f.decrActive(job.Queue)
		resultStatus = "cancelling"
	default:
		return &store.OpResult{Err: fmt.Errorf("job %q cannot be cancelled from state %q", op.JobID, job.State)}
	}

	job.State = store.StateCancelled
	jobData, _ := encodeJobDoc(job)
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit cancel: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteCancelJob(db, op.JobID)
	})

	return &store.OpResult{Data: resultStatus}
}

// --- MoveJob ---

func (f *FSM) applyMoveJob(data json.RawMessage) *store.OpResult {
	var op store.MoveJobOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyMoveJobOp(op)
}

func (f *FSM) applyMoveJobOp(op store.MoveJobOp) *store.OpResult {
	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %q not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %q: %w", op.JobID, err)}
	}
	closer.Close()

	batch := f.pebble.NewBatch()
	defer batch.Close()

	oldQueue := job.Queue

	// Remove from old queue's sorted set based on state
	switch job.State {
	case store.StatePending:
		deletePendingOrAppendKey(batch, f.pebble, oldQueue, op.JobID, f.writeOpts)
	case store.StateActive:
		batch.Delete(kv.ActiveKey(oldQueue, op.JobID), f.writeOpts)
		f.decrActive(oldQueue)
	case store.StateScheduled:
		deleteScheduledKey(batch, f.pebble, oldQueue, op.JobID, f.writeOpts)
	case store.StateRetrying:
		deleteRetryingKey(batch, f.pebble, oldQueue, op.JobID, f.writeOpts)
	}

	job.Queue = op.TargetQueue
	jobData, _ := encodeJobDoc(job)
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
	batch.Set(kv.QueueNameKey(op.TargetQueue), nil, f.writeOpts)

	// Add to new queue's sorted set
	switch job.State {
	case store.StatePending:
		createdNs := op.NowNs
		if job.Priority == store.PriorityNormal {
			batch.Set(kv.QueueAppendKey(op.TargetQueue, createdNs, op.JobID), nil, f.writeOpts)
		} else {
			batch.Set(kv.PendingKey(op.TargetQueue, uint8(job.Priority), createdNs, op.JobID), nil, f.writeOpts)
		}
	case store.StateActive:
		var leaseNs uint64
		if job.LeaseExpiresAt != nil {
			leaseNs = uint64(job.LeaseExpiresAt.UnixNano())
		}
		batch.Set(kv.ActiveKey(op.TargetQueue, op.JobID), kv.PutUint64BE(nil, leaseNs), f.writeOpts)
		f.incrActive(op.TargetQueue)
	case store.StateScheduled:
		if job.ScheduledAt != nil {
			schedNs := uint64(job.ScheduledAt.UnixNano())
			batch.Set(kv.ScheduledKey(op.TargetQueue, schedNs, op.JobID), nil, f.writeOpts)
		}
	case store.StateRetrying:
		if job.ScheduledAt != nil {
			retryNs := uint64(job.ScheduledAt.UnixNano())
			batch.Set(kv.RetryingKey(op.TargetQueue, retryNs, op.JobID), nil, f.writeOpts)
		}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit move: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteMoveJob(db, op.JobID, op.TargetQueue)
	})

	return &store.OpResult{Data: nil}
}

// --- Budgets ---

func (f *FSM) applySetBudget(data json.RawMessage) *store.OpResult {
	var op store.SetBudgetOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applySetBudgetOp(op)
}

func (f *FSM) applySetBudgetOp(op store.SetBudgetOp) *store.OpResult {
	doc := store.Budget{
		ID:        op.ID,
		Scope:     op.Scope,
		Target:    op.Target,
		DailyUSD:  op.DailyUSD,
		PerJobUSD: op.PerJobUSD,
		OnExceed:  op.OnExceed,
		CreatedAt: op.CreatedAt,
	}
	b, err := json.Marshal(doc)
	if err != nil {
		return &store.OpResult{Err: err}
	}
	if err := f.pebble.Set(kv.BudgetKey(op.Scope, op.Target), b, f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}
	f.syncSQLite(func(db sqlExecer) error {
		return sqliteUpsertBudget(db, doc)
	})
	return &store.OpResult{Data: nil}
}

func (f *FSM) applyDeleteBudget(data json.RawMessage) *store.OpResult {
	var op store.DeleteBudgetOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyDeleteBudgetOp(op)
}

func (f *FSM) applyDeleteBudgetOp(op store.DeleteBudgetOp) *store.OpResult {
	if err := f.pebble.Delete(kv.BudgetKey(op.Scope, op.Target), f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}
	f.syncSQLite(func(db sqlExecer) error {
		return sqliteDeleteBudget(db, op.Scope, op.Target)
	})
	return &store.OpResult{Data: nil}
}

// --- DeleteJob ---

func (f *FSM) applyDeleteJob(data json.RawMessage) *store.OpResult {
	var op store.DeleteJobOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyDeleteJobOp(op)
}

func (f *FSM) applyDeleteJobOp(op store.DeleteJobOp) *store.OpResult {
	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %q not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %q: %w", op.JobID, err)}
	}
	closer.Close()

	batch := f.pebble.NewBatch()
	defer batch.Close()

	batch.Delete(kv.JobKey(op.JobID), f.writeOpts)

	// Remove from queue sorted set
	switch job.State {
	case store.StatePending:
		deletePendingOrAppendKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
	case store.StateActive:
		batch.Delete(kv.ActiveKey(job.Queue, op.JobID), f.writeOpts)
		f.decrActive(job.Queue)
	case store.StateScheduled:
		deleteScheduledKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
	case store.StateRetrying:
		deleteRetryingKey(batch, f.pebble, job.Queue, op.JobID, f.writeOpts)
	}

	// Delete error records
	deletePrefix(batch, f.pebble, kv.JobErrorPrefix(op.JobID), f.writeOpts)

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit delete: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteDeleteJob(db, op.JobID)
	})

	return &store.OpResult{Data: nil}
}

// --- Queue operations ---

func (f *FSM) applyPauseQueue(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyPauseQueueOp(op)
}

func (f *FSM) applyPauseQueueOp(op store.QueueOp) *store.OpResult {
	return f.setQueuePaused(op.Queue, true)
}

func (f *FSM) applyResumeQueue(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyResumeQueueOp(op)
}

func (f *FSM) applyResumeQueueOp(op store.QueueOp) *store.OpResult {
	return f.setQueuePaused(op.Queue, false)
}

func (f *FSM) setQueuePaused(queue string, paused bool) *store.OpResult {
	qc := f.getOrCreateQueueConfig(queue)
	qc.Paused = paused
	qcData, _ := json.Marshal(qc)

	batch := f.pebble.NewBatch()
	defer batch.Close()
	batch.Set(kv.QueueConfigKey(queue), qcData, f.writeOpts)
	batch.Set(kv.QueueNameKey(queue), nil, f.writeOpts)
	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}

	val := 0
	if paused {
		val = 1
	}
	f.syncSQLite(func(db sqlExecer) error {
		return sqliteUpdateQueueField(db, queue, "paused", val)
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applyClearQueue(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyClearQueueOp(op)
}

func (f *FSM) applyClearQueueOp(op store.QueueOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Delete pending jobs
	f.deleteJobsByPrefix(batch, kv.PendingPrefix(op.Queue))
	// Delete scheduled jobs
	f.deleteJobsByPrefix(batch, kv.ScheduledScanPrefix(op.Queue))

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit clear: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM jobs WHERE queue = ? AND state IN ('pending', 'scheduled')", op.Queue)
		return err
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applyDeleteQueue(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyDeleteQueueOp(op)
}

func (f *FSM) applyDeleteQueueOp(op store.QueueOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Delete all jobs in all states
	f.deleteJobsByPrefix(batch, kv.PendingPrefix(op.Queue))
	f.deleteJobsByPrefix(batch, kv.ActivePrefix(op.Queue))
	f.resetActiveCount(op.Queue)
	f.deleteJobsByPrefix(batch, kv.ScheduledScanPrefix(op.Queue))
	f.deleteJobsByPrefix(batch, kv.RetryingScanPrefix(op.Queue))

	// Delete queue config, name, rate limits, unique locks
	batch.Delete(kv.QueueConfigKey(op.Queue), f.writeOpts)
	batch.Delete(kv.QueueNameKey(op.Queue), f.writeOpts)
	deletePrefix(batch, f.pebble, kv.RateLimitPrefix(op.Queue), f.writeOpts)
	deletePrefix(batch, f.pebble, kv.UniquePrefix(op.Queue), f.writeOpts)

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit delete queue: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteDeleteQueue(db, op.Queue)
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applySetConcurrency(data json.RawMessage) *store.OpResult {
	var op store.SetConcurrencyOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applySetConcurrencyOp(op)
}

func (f *FSM) applySetConcurrencyOp(op store.SetConcurrencyOp) *store.OpResult {
	qc := f.getOrCreateQueueConfig(op.Queue)
	if op.Max <= 0 {
		qc.MaxConcurrency = nil
	} else {
		qc.MaxConcurrency = &op.Max
	}
	qcData, _ := json.Marshal(qc)

	batch := f.pebble.NewBatch()
	defer batch.Close()
	batch.Set(kv.QueueConfigKey(op.Queue), qcData, f.writeOpts)
	batch.Set(kv.QueueNameKey(op.Queue), nil, f.writeOpts)
	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}

	f.syncSQLite(func(db sqlExecer) error {
		var val any
		if op.Max > 0 {
			val = op.Max
		}
		return sqliteUpdateQueueField(db, op.Queue, "max_concurrency", val)
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applySetThrottle(data json.RawMessage) *store.OpResult {
	var op store.SetThrottleOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applySetThrottleOp(op)
}

func (f *FSM) applySetThrottleOp(op store.SetThrottleOp) *store.OpResult {
	qc := f.getOrCreateQueueConfig(op.Queue)
	qc.RateLimit = &op.Rate
	qc.RateWindowMs = &op.WindowMs
	qcData, _ := json.Marshal(qc)

	batch := f.pebble.NewBatch()
	defer batch.Close()
	batch.Set(kv.QueueConfigKey(op.Queue), qcData, f.writeOpts)
	batch.Set(kv.QueueNameKey(op.Queue), nil, f.writeOpts)
	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}

	f.syncSQLite(func(db sqlExecer) error {
		db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", op.Queue)
		_, err := db.Exec("UPDATE queues SET rate_limit = ?, rate_window_ms = ? WHERE name = ?",
			op.Rate, op.WindowMs, op.Queue)
		return err
	})

	return &store.OpResult{Data: nil}
}

func (f *FSM) applyRemoveThrottle(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyRemoveThrottleOp(op)
}

func (f *FSM) applyRemoveThrottleOp(op store.QueueOp) *store.OpResult {
	qc := f.getOrCreateQueueConfig(op.Queue)
	qc.RateLimit = nil
	qc.RateWindowMs = nil
	qcData, _ := json.Marshal(qc)

	if err := f.pebble.Set(kv.QueueConfigKey(op.Queue), qcData, f.writeOpts); err != nil {
		return &store.OpResult{Err: err}
	}

	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("UPDATE queues SET rate_limit = NULL, rate_window_ms = NULL WHERE name = ?", op.Queue)
		return err
	})

	return &store.OpResult{Data: nil}
}

// --- Promote ---

func (f *FSM) applyPromote(data json.RawMessage) *store.OpResult {
	var op store.PromoteOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyPromoteOp(op)
}

func (f *FSM) applyPromoteOp(op store.PromoteOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	var promoted int

	// Scan all queues for scheduled jobs ready to promote
	qnIter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: []byte(kv.PrefixQueueName),
		UpperBound: prefixUpperBound([]byte(kv.PrefixQueueName)),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer qnIter.Close()

	var queues []string
	for qnIter.First(); qnIter.Valid(); qnIter.Next() {
		queue := string(qnIter.Key()[len(kv.PrefixQueueName):])
		queues = append(queues, queue)
	}

	for _, queue := range queues {
		// Promote scheduled
		promoted += f.promotePrefix(batch, kv.ScheduledScanPrefix(queue), queue, op.NowNs)
		// Promote retrying
		promoted += f.promotePrefix(batch, kv.RetryingScanPrefix(queue), queue, op.NowNs)
	}

	if promoted == 0 {
		return &store.OpResult{Data: 0}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit promote: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		nowStr := time.Unix(0, int64(op.NowNs)).UTC().Format(time.RFC3339Nano)
		_, err := db.Exec(`UPDATE jobs SET state = 'pending', scheduled_at = NULL
			WHERE state IN ('scheduled', 'retrying') AND scheduled_at <= ?`, nowStr)
		return err
	})

	return &store.OpResult{Data: promoted}
}

func (f *FSM) promotePrefix(batch *pebble.Batch, prefix []byte, queue string, nowNs uint64) int {
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return 0
	}
	defer iter.Close()

	var promoted int
	for iter.First(); iter.Valid(); iter.Next() {
		// Extract scheduled_ns from key: prefix + 8byte timestamp + jobID
		key := iter.Key()
		tsOffset := len(prefix)
		if len(key) < tsOffset+8 {
			continue
		}
		scheduledNs := kv.GetUint64BE(key[tsOffset : tsOffset+8])
		if scheduledNs > nowNs {
			break // sorted — no more ready
		}

		jobID := string(key[tsOffset+8:])

		// Read job
		jobVal, closer, err := f.pebble.Get(kv.JobKey(jobID))
		if err != nil {
			continue
		}
		var job store.Job
		if err := decodeJobDoc(jobVal, &job); err != nil {
			closer.Close()
			continue
		}
		closer.Close()

		// Update to pending
		job.State = store.StatePending
		job.ScheduledAt = nil
		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)

		// Delete from scheduled/retrying set
		k := make([]byte, len(key))
		copy(k, key)
		batch.Delete(k, f.writeOpts)

		createdNs := nowNs
		if job.Priority == store.PriorityNormal {
			batch.Set(kv.QueueAppendKey(queue, createdNs, jobID), nil, f.writeOpts)
		} else {
			batch.Set(kv.PendingKey(queue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
		}

		promoted++
	}
	return promoted
}

// --- Reclaim ---

func (f *FSM) applyReclaim(data json.RawMessage) *store.OpResult {
	var op store.ReclaimOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyReclaimOp(op)
}

func (f *FSM) applyReclaimOp(op store.ReclaimOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	var reclaimed int

	// Scan all queues
	qnIter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: []byte(kv.PrefixQueueName),
		UpperBound: prefixUpperBound([]byte(kv.PrefixQueueName)),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer qnIter.Close()

	var queues []string
	for qnIter.First(); qnIter.Valid(); qnIter.Next() {
		queue := string(qnIter.Key()[len(kv.PrefixQueueName):])
		queues = append(queues, queue)
	}

	now := time.Unix(0, int64(op.NowNs))

	for _, queue := range queues {
		prefix := kv.ActivePrefix(queue)
		iter, err := f.pebble.NewIter(&pebble.IterOptions{
			LowerBound: prefix,
			UpperBound: prefixUpperBound(prefix),
		})
		if err != nil {
			continue
		}

		type reclaimEntry struct {
			key   []byte
			jobID string
		}
		var toReclaim []reclaimEntry

		for iter.First(); iter.Valid(); iter.Next() {
			val := iter.Value()
			if len(val) < 8 {
				continue
			}
			leaseExpiresNs := kv.GetUint64BE(val)
			if leaseExpiresNs >= op.NowNs {
				continue // lease still valid
			}

			jobID := string(iter.Key()[len(prefix):])
			k := make([]byte, len(iter.Key()))
			copy(k, iter.Key())
			toReclaim = append(toReclaim, reclaimEntry{key: k, jobID: jobID})
		}
		iter.Close()

		for _, entry := range toReclaim {
			jobVal, closer, err := f.pebble.Get(kv.JobKey(entry.jobID))
			if err != nil {
				continue
			}
			var job store.Job
			if err := decodeJobDoc(jobVal, &job); err != nil {
				closer.Close()
				continue
			}
			closer.Close()

			job.State = store.StatePending
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			jobData, _ := encodeJobDoc(job)

			batch.Set(kv.JobKey(entry.jobID), jobData, f.writeOpts)
			batch.Delete(entry.key, f.writeOpts) // active key
			f.decrActive(queue)
			createdNs := op.NowNs
			if job.Priority == store.PriorityNormal {
				batch.Set(kv.QueueAppendKey(queue, createdNs, entry.jobID), nil, f.writeOpts)
			} else {
				batch.Set(kv.PendingKey(queue, uint8(job.Priority), createdNs, entry.jobID), nil, f.writeOpts)
			}
			reclaimed++
		}
	}

	if reclaimed == 0 {
		return &store.OpResult{Data: 0}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit reclaim: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		nowStr := now.UTC().Format(time.RFC3339Nano)
		_, err := db.Exec(`UPDATE jobs SET state = 'pending', worker_id = NULL, hostname = NULL, lease_expires_at = NULL
			WHERE state = 'active' AND lease_expires_at < ?`, nowStr)
		return err
	})

	return &store.OpResult{Data: reclaimed}
}

// --- BulkAction ---

func (f *FSM) applyBulkAction(data json.RawMessage) *store.OpResult {
	var op store.BulkActionOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyBulkActionOp(op)
}

func (f *FSM) applyBulkActionOp(op store.BulkActionOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	var affected int
	lifecycleChanged := false

	for _, jobID := range op.JobIDs {
		jobVal, closer, err := f.pebble.Get(kv.JobKey(jobID))
		if err != nil {
			continue
		}
		var job store.Job
		if err := decodeJobDoc(jobVal, &job); err != nil {
			closer.Close()
			continue
		}
		closer.Close()

		switch op.Action {
		case "retry":
			if job.State != store.StateDead && job.State != store.StateCancelled && job.State != store.StateCompleted && job.State != store.StateScheduled {
				continue
			}
			f.removeFromSortedSet(batch, job)
			now := time.Unix(0, int64(op.NowNs))
			createdNs := uint64(now.UnixNano())
			job.State = store.StatePending
			job.Attempt = 0
			job.FailedAt = nil
			job.CompletedAt = nil
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			job.ScheduledAt = nil
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if job.Priority == store.PriorityNormal {
				batch.Set(kv.QueueAppendKey(job.Queue, createdNs, jobID), nil, f.writeOpts)
			} else {
				batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
			}
			affected++

		case "delete":
			f.removeFromSortedSet(batch, job)
			batch.Delete(kv.JobKey(jobID), f.writeOpts)
			deletePrefix(batch, f.pebble, kv.JobErrorPrefix(jobID), f.writeOpts)
			affected++

		case "cancel":
			if job.State != store.StatePending && job.State != store.StateActive &&
				job.State != store.StateScheduled && job.State != store.StateRetrying {
				continue
			}
			f.removeFromSortedSet(batch, job)
			job.State = store.StateCancelled
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			affected++

		case "move":
			f.removeFromSortedSet(batch, job)
			oldQueue := job.Queue
			_ = oldQueue
			job.Queue = op.MoveToQueue
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			batch.Set(kv.QueueNameKey(op.MoveToQueue), nil, f.writeOpts)
			if job.State == store.StatePending {
				createdNs := op.NowNs
				if job.Priority == store.PriorityNormal {
					batch.Set(kv.QueueAppendKey(op.MoveToQueue, createdNs, jobID), nil, f.writeOpts)
				} else {
					batch.Set(kv.PendingKey(op.MoveToQueue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
				}
			}
			affected++

		case "requeue":
			if job.State != store.StateDead {
				continue
			}
			now := time.Unix(0, int64(op.NowNs))
			createdNs := uint64(now.UnixNano())
			job.State = store.StatePending
			job.FailedAt = nil
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			job.ScheduledAt = nil
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if job.Priority == store.PriorityNormal {
				batch.Set(kv.QueueAppendKey(job.Queue, createdNs, jobID), nil, f.writeOpts)
			} else {
				batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
			}
			affected++

		case "change_priority":
			if job.State != store.StatePending && job.State != store.StateScheduled {
				continue
			}
			if job.State == store.StatePending {
				deletePendingOrAppendKey(batch, f.pebble, job.Queue, jobID, f.writeOpts)
				job.Priority = op.Priority
				createdNs := op.NowNs
				if job.Priority == store.PriorityNormal {
					batch.Set(kv.QueueAppendKey(job.Queue, createdNs, jobID), nil, f.writeOpts)
				} else {
					batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
				}
			} else {
				job.Priority = op.Priority
			}
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			affected++

		case "hold":
			if job.State != store.StatePending && job.State != store.StateActive &&
				job.State != store.StateScheduled && job.State != store.StateRetrying {
				continue
			}
			f.removeFromSortedSet(batch, job)
			job.State = store.StateHeld
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			job.ScheduledAt = nil
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if err := f.appendLifecycleEvent(batch, "held", jobID, job.Queue, op.NowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			lifecycleChanged = true
			affected++

		case "approve":
			if job.State != store.StateHeld {
				continue
			}
			job.State = store.StatePending
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			job.ScheduledAt = nil
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			createdNs := op.NowNs
			if job.Priority == store.PriorityNormal {
				batch.Set(kv.QueueAppendKey(job.Queue, createdNs, jobID), nil, f.writeOpts)
			} else {
				batch.Set(kv.PendingKey(job.Queue, uint8(job.Priority), createdNs, jobID), nil, f.writeOpts)
			}
			if err := f.appendLifecycleEvent(batch, "approved", jobID, job.Queue, op.NowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			lifecycleChanged = true
			affected++

		case "reject":
			if job.State != store.StateHeld {
				continue
			}
			now := time.Unix(0, int64(op.NowNs))
			job.State = store.StateDead
			job.FailedAt = &now
			job.WorkerID = nil
			job.Hostname = nil
			job.LeaseExpiresAt = nil
			job.ScheduledAt = nil
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			if err := f.appendLifecycleEvent(batch, "rejected", jobID, job.Queue, op.NowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			lifecycleChanged = true
			affected++
		}
	}

	if lifecycleChanged {
		if err := f.appendLifecycleCursor(batch); err != nil {
			return &store.OpResult{Err: err}
		}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit bulk: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteBulkAction(db, op)
	})

	return &store.OpResult{Data: &store.BulkResult{
		Affected: affected,
	}}
}

// --- CleanUnique ---

func (f *FSM) applyCleanUnique(data json.RawMessage) *store.OpResult {
	var op store.CleanUniqueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyCleanUniqueOp(op)
}

func (f *FSM) applyCleanUniqueOp(op store.CleanUniqueOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	var cleaned int

	// Scan all unique keys
	prefix := []byte(kv.PrefixUnique)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		val := iter.Value()
		_, expiresNs := kv.DecodeUniqueValue(val)
		if expiresNs < op.NowNs {
			k := make([]byte, len(iter.Key()))
			copy(k, iter.Key())
			batch.Delete(k, f.writeOpts)
			cleaned++
		}
	}

	if cleaned > 0 {
		if err := batch.Commit(f.writeOpts); err != nil {
			return &store.OpResult{Err: err}
		}
	}

	f.syncSQLite(func(db sqlExecer) error {
		nowStr := time.Unix(0, int64(op.NowNs)).UTC().Format(time.RFC3339Nano)
		_, err := db.Exec("DELETE FROM unique_locks WHERE expires_at < ?", nowStr)
		return err
	})

	return &store.OpResult{Data: cleaned}
}

// --- CleanRateLimit ---

func (f *FSM) applyCleanRateLimit(data json.RawMessage) *store.OpResult {
	var op store.CleanRateLimitOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyCleanRateLimitOp(op)
}

func (f *FSM) applyCleanRateLimitOp(op store.CleanRateLimitOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	var cleaned int

	prefix := []byte(kv.PrefixRateLimit)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		// Key: l|{queue}\x00{fetched_ns:8BE}{random:8BE}
		// We need to extract fetched_ns. Find the \x00 separator after the queue name.
		key := iter.Key()
		prefixLen := len(kv.PrefixRateLimit)
		sepIdx := -1
		for i := prefixLen; i < len(key); i++ {
			if key[i] == 0 {
				sepIdx = i
				break
			}
		}
		if sepIdx == -1 || len(key) < sepIdx+1+8 {
			continue
		}
		fetchedNs := kv.GetUint64BE(key[sepIdx+1 : sepIdx+9])
		if fetchedNs < op.CutoffNs {
			k := make([]byte, len(key))
			copy(k, key)
			batch.Delete(k, f.writeOpts)
			cleaned++
		}
	}

	if cleaned > 0 {
		if err := batch.Commit(f.writeOpts); err != nil {
			return &store.OpResult{Err: err}
		}
	}

	f.syncSQLite(func(db sqlExecer) error {
		cutoffStr := time.Unix(0, int64(op.CutoffNs)).UTC().Format(time.RFC3339Nano)
		_, err := db.Exec("DELETE FROM rate_limit_window WHERE fetched_at < ?", cutoffStr)
		return err
	})

	return &store.OpResult{Data: cleaned}
}

// --- Helpers ---

func (f *FSM) getOrCreateQueueConfig(queue string) store.Queue {
	val, closer, err := f.pebble.Get(kv.QueueConfigKey(queue))
	if err == nil {
		defer closer.Close()
		var qc store.Queue
		if err := json.Unmarshal(val, &qc); err != nil {
			return store.Queue{Name: queue}
		}
		return qc
	}
	return store.Queue{Name: queue}
}

func (f *FSM) updateBatchPebble(batch *pebble.Batch, batchID, outcome string, nowNs uint64) string {
	bVal, closer, err := f.pebble.Get(kv.BatchKey(batchID))
	if err != nil {
		return ""
	}
	var b store.Batch
	if err := json.Unmarshal(bVal, &b); err != nil {
		closer.Close()
		return ""
	}
	closer.Close()

	b.Pending--
	if outcome == "success" {
		b.Succeeded++
	} else {
		b.Failed++
	}

	bData, _ := json.Marshal(b)
	batch.Set(kv.BatchKey(batchID), bData, f.writeOpts)

	// If all done, enqueue callback
	if b.Pending <= 0 && b.CallbackQueue != nil {
		callbackJobID := store.NewJobID()
		payload := json.RawMessage("{}")
		if len(b.CallbackPayload) > 0 {
			payload = b.CallbackPayload
		}
		now := time.Unix(0, int64(nowNs))
		callbackJob := store.Job{
			ID:        callbackJobID,
			Queue:     *b.CallbackQueue,
			State:     store.StatePending,
			Payload:   payload,
			Priority:  store.PriorityNormal,
			CreatedAt: now,
		}
		jobData, _ := json.Marshal(callbackJob)
		batch.Set(kv.JobKey(callbackJobID), jobData, f.writeOpts)
		createdNs := uint64(now.UnixNano())
		batch.Set(kv.PendingKey(*b.CallbackQueue, uint8(store.PriorityNormal), createdNs, callbackJobID), nil, f.writeOpts)
		return callbackJobID
	}
	return ""
}

func (f *FSM) deleteJobsByPrefix(batch *pebble.Batch, prefix []byte) {
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		// Extract jobID
		prefixLen := len(prefix)
		var jobID string

		// For pending keys: prefix + 1byte + 8byte + jobID
		// For scheduled/retrying: prefix + 8byte + jobID
		// For active: prefix + jobID
		// We just need to delete the sorted-set key and the job key.
		// But we don't know the format generically. Instead, just delete the sorted set key
		// and find the jobID from the job key data.
		// Actually, since we iterate, let's just collect and process.

		// Determine format based on prefix
		if len(key) > prefixLen {
			switch {
			case key[0] == 'p': // pending: prefix + 1 + 8 + jobID
				if len(key) > prefixLen+9 {
					jobID = string(key[prefixLen+9:])
				}
			case key[0] == 's' || key[0] == 'r': // scheduled/retrying: prefix + 8 + jobID
				if len(key) > prefixLen+8 {
					jobID = string(key[prefixLen+8:])
				}
			case key[0] == 'a': // active: prefix + jobID
				jobID = string(key[prefixLen:])
			}
		}

		k := make([]byte, len(key))
		copy(k, key)
		batch.Delete(k, f.writeOpts)

		if jobID != "" {
			batch.Delete(kv.JobKey(jobID), f.writeOpts)
			deletePrefix(batch, f.pebble, kv.JobErrorPrefix(jobID), f.writeOpts)
		}
	}
}

// jobToDoc creates a store.Job from an EnqueueOp for Pebble storage.
func jobToDoc(op store.EnqueueOp) store.Job {
	j := store.Job{
		ID:             op.JobID,
		Queue:          op.Queue,
		State:          op.State,
		Payload:        op.Payload,
		Checkpoint:     op.Checkpoint,
		Priority:       op.Priority,
		MaxRetries:     op.MaxRetries,
		RetryBackoff:   op.Backoff,
		RetryBaseDelay: op.BaseDelayMs,
		RetryMaxDelay:  op.MaxDelayMs,
		CreatedAt:      op.CreatedAt,
		Tags:           op.Tags,
		Agent:          op.Agent,
	}
	if op.UniqueKey != "" {
		j.UniqueKey = &op.UniqueKey
	}
	if op.BatchID != "" {
		j.BatchID = &op.BatchID
	}
	if op.ScheduledAt != nil {
		j.ScheduledAt = op.ScheduledAt
	}
	if op.ExpireAt != nil {
		j.ExpireAt = op.ExpireAt
	}
	if op.ParentID != "" {
		j.ParentID = &op.ParentID
	}
	if op.ChainID != "" {
		j.ChainID = &op.ChainID
	}
	if op.ChainStep != nil {
		j.ChainStep = op.ChainStep
	}
	if len(op.ChainConfig) > 0 {
		j.ChainConfig = op.ChainConfig
	}
	return j
}

func marshalStringSlice(ss []string) json.RawMessage {
	b, _ := json.Marshal(ss)
	return b
}

// countPrefix counts keys with the given prefix.
func countPrefix(db *pebble.DB, prefix []byte) int {
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return 0
	}
	defer iter.Close()
	count := 0
	for iter.First(); iter.Valid(); iter.Next() {
		count++
	}
	return count
}

// countPrefixFrom counts keys from startKey to the upper bound of prefix.
func countPrefixFrom(db *pebble.DB, prefix, startKey []byte) int {
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: startKey,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return 0
	}
	defer iter.Close()
	count := 0
	for iter.First(); iter.Valid(); iter.Next() {
		count++
	}
	return count
}

// prefixUpperBound returns the first key that is not a prefix match.
func prefixUpperBound(prefix []byte) []byte {
	upper := make([]byte, len(prefix))
	copy(upper, prefix)
	for i := len(upper) - 1; i >= 0; i-- {
		upper[i]++
		if upper[i] != 0 {
			return upper
		}
	}
	return nil // all 0xFF — no upper bound
}

// deletePrefix deletes all keys with the given prefix from pebble via batch.
func deletePrefix(batch *pebble.Batch, db *pebble.DB, prefix []byte, writeOpts *pebble.WriteOptions) {
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()
	for iter.First(); iter.Valid(); iter.Next() {
		k := make([]byte, len(iter.Key()))
		copy(k, iter.Key())
		batch.Delete(k, writeOpts)
	}
}

// deletePendingKey finds and deletes a job's pending key by scanning the prefix.
func deletePendingKey(batch *pebble.Batch, db *pebble.DB, queue, jobID string, writeOpts *pebble.WriteOptions) {
	prefix := kv.PendingPrefix(queue)
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()
	suffix := []byte(jobID)
	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		if len(key) >= len(suffix) && string(key[len(key)-len(suffix):]) == jobID {
			k := make([]byte, len(key))
			copy(k, key)
			batch.Delete(k, writeOpts)
			return
		}
	}
}

func deleteAppendKey(batch *pebble.Batch, db *pebble.DB, queue, jobID string, writeOpts *pebble.WriteOptions) {
	prefix := kv.QueueAppendPrefix(queue)
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()
	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		if len(key) >= len(jobID) && string(key[len(key)-len(jobID):]) == jobID {
			k := make([]byte, len(key))
			copy(k, key)
			batch.Delete(k, writeOpts)
			return
		}
	}
}

func deletePendingOrAppendKey(batch *pebble.Batch, db *pebble.DB, queue, jobID string, writeOpts *pebble.WriteOptions) {
	deletePendingKey(batch, db, queue, jobID, writeOpts)
	deleteAppendKey(batch, db, queue, jobID, writeOpts)
}

// deleteScheduledKey finds and deletes a job's scheduled key.
func deleteScheduledKey(batch *pebble.Batch, db *pebble.DB, queue, jobID string, writeOpts *pebble.WriteOptions) {
	prefix := kv.ScheduledScanPrefix(queue)
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()
	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		if len(key) >= len(jobID) && string(key[len(key)-len(jobID):]) == jobID {
			k := make([]byte, len(key))
			copy(k, key)
			batch.Delete(k, writeOpts)
			return
		}
	}
}

// deleteRetryingKey finds and deletes a job's retrying key.
func deleteRetryingKey(batch *pebble.Batch, db *pebble.DB, queue, jobID string, writeOpts *pebble.WriteOptions) {
	prefix := kv.RetryingScanPrefix(queue)
	iter, err := db.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return
	}
	defer iter.Close()
	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		if len(key) >= len(jobID) && string(key[len(key)-len(jobID):]) == jobID {
			k := make([]byte, len(key))
			copy(k, key)
			batch.Delete(k, writeOpts)
			return
		}
	}
}

// removeFromSortedSet removes a job from whatever sorted set it's in.
func (f *FSM) removeFromSortedSet(batch *pebble.Batch, job store.Job) {
	switch job.State {
	case store.StatePending:
		deletePendingOrAppendKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
	case store.StateActive:
		batch.Delete(kv.ActiveKey(job.Queue, job.ID), f.writeOpts)
		f.decrActive(job.Queue)
	case store.StateScheduled:
		deleteScheduledKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
	case store.StateRetrying:
		deleteRetryingKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
	}
}

// --- ExpireJobs ---

func (f *FSM) applyExpireJobs(data json.RawMessage) *store.OpResult {
	var op store.ExpireJobsOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyExpireJobsOp(op)
}

func (f *FSM) applyExpireJobsOp(op store.ExpireJobsOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	now := time.Unix(0, int64(op.NowNs))
	var expired int
	var sqliteUpdates []string

	prefix := []byte(kv.PrefixJob)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		var job store.Job
		if err := decodeJobDoc(iter.Value(), &job); err != nil {
			continue
		}
		if job.ExpireAt == nil || !job.ExpireAt.Before(now) {
			continue
		}
		// Only expire non-terminal, non-active jobs
		switch job.State {
		case store.StatePending, store.StateScheduled, store.StateRetrying, store.StateHeld:
		default:
			continue
		}

		// Remove from queue index
		switch job.State {
		case store.StatePending:
			deletePendingOrAppendKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
		case store.StateScheduled:
			deleteScheduledKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
		case store.StateRetrying:
			deleteRetryingKey(batch, f.pebble, job.Queue, job.ID, f.writeOpts)
		}

		// Write error record
		errDoc := store.JobError{
			JobID:     job.ID,
			Attempt:   job.Attempt,
			Error:     "job expired",
			CreatedAt: now,
		}
		errData, _ := json.Marshal(errDoc)
		batch.Set(kv.JobErrorKey(job.ID, uint32(job.Attempt)), errData, f.writeOpts)

		// Update job state
		job.State = store.StateDead
		job.FailedAt = &now
		jobData, _ := encodeJobDoc(job)
		batch.Set(kv.JobKey(job.ID), jobData, f.writeOpts)

		sqliteUpdates = append(sqliteUpdates, job.ID)
		expired++
	}

	if expired > 0 {
		if err := batch.Commit(f.writeOpts); err != nil {
			return &store.OpResult{Err: err}
		}
	}

	if len(sqliteUpdates) > 0 {
		nowStr := now.UTC().Format(time.RFC3339Nano)
		f.syncSQLite(func(db sqlExecer) error {
			for _, jobID := range sqliteUpdates {
				db.Exec("UPDATE jobs SET state = 'dead', failed_at = ? WHERE id = ?", nowStr, jobID)
				db.Exec("INSERT INTO job_errors (job_id, attempt, error, created_at) VALUES (?, 0, 'job expired', ?)", jobID, nowStr)
			}
			return nil
		})
	}

	return &store.OpResult{Data: expired}
}

// --- PurgeJobs ---

func (f *FSM) applyPurgeJobs(data json.RawMessage) *store.OpResult {
	var op store.PurgeJobsOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
	return f.applyPurgeJobsOp(op)
}

func (f *FSM) applyPurgeJobsOp(op store.PurgeJobsOp) *store.OpResult {
	batch := f.pebble.NewBatch()
	defer batch.Close()

	cutoff := time.Unix(0, int64(op.CutoffNs))
	var purged int
	var sqliteDeletes []string

	prefix := []byte(kv.PrefixJob)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return &store.OpResult{Err: err}
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		var job store.Job
		if err := decodeJobDoc(iter.Value(), &job); err != nil {
			continue
		}

		var ts time.Time
		switch job.State {
		case store.StateCompleted:
			if job.CompletedAt == nil {
				continue
			}
			ts = *job.CompletedAt
		case store.StateDead:
			if job.FailedAt != nil {
				ts = *job.FailedAt
			} else {
				ts = job.CreatedAt
			}
		case store.StateCancelled:
			if job.FailedAt != nil {
				ts = *job.FailedAt
			} else {
				ts = job.CreatedAt
			}
		default:
			continue
		}

		if !ts.Before(cutoff) {
			continue
		}

		// Delete job key
		k := make([]byte, len(iter.Key()))
		copy(k, iter.Key())
		batch.Delete(k, f.writeOpts)

		// Delete error records
		deletePrefix(batch, f.pebble, kv.JobErrorPrefix(job.ID), f.writeOpts)

		sqliteDeletes = append(sqliteDeletes, job.ID)
		purged++
	}

	if purged > 0 {
		if err := batch.Commit(f.writeOpts); err != nil {
			return &store.OpResult{Err: err}
		}
	}

	if len(sqliteDeletes) > 0 {
		f.syncSQLite(func(db sqlExecer) error {
			for _, jobID := range sqliteDeletes {
				sqliteDeleteJob(db, jobID)
			}
			return nil
		})
	}

	return &store.OpResult{Data: purged}
}
