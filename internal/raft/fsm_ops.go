package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/user/jobbie/internal/kv"
	"github.com/user/jobbie/internal/store"
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
			results[i] = &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
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
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		for i := range results {
			results[i] = &store.OpResult{Err: fmt.Errorf("pebble commit: %w", err)}
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
				activeCount := countPrefix(f.pebble, kv.ActivePrefix(queue))
				if activeCount >= *qc.MaxConcurrency {
					continue
				}
			}

			// Check rate limit
			if qc.RateLimit != nil && qc.RateWindowMs != nil && *qc.RateLimit > 0 {
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

		// Record rate limit entry
		batch.Set(kv.RateLimitKey(queue, nowNs, op.RandomSeed), nil, f.writeOpts)

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
				qs.activeCount = countPrefix(f.pebble, kv.ActivePrefix(queue))
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
			batch.Set(kv.RateLimitKey(qs.name, nowNs, op.RandomSeed+rateSeq), nil, f.writeOpts)
			rateSeq++
			if err := f.appendLifecycleEvent(batch, "started", jobID, qs.name, nowNs); err != nil {
				return &store.OpResult{Err: err}
			}
			if qs.activeLimit > 0 {
				qs.activeCount++
			}
			if qs.rateLimit > 0 {
				qs.rateCount++
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
		activeCount := countPrefix(f.pebble, kv.ActivePrefix(queue))
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
			continue
		}
		var doc store.Job
		if err := decodeJobDoc(val, &doc); err != nil {
			closer.Close()
			continue
		}
		closer.Close()

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
	if len(lower) > 0 {
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
		ak := make([]byte, len(key))
		copy(ak, key)
		return id, ak, doc, true
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

	batch := f.pebble.NewBatch()
	defer batch.Close()

	now := time.Unix(0, int64(op.NowNs))
	job.State = store.StateCompleted
	job.CompletedAt = &now
	if len(op.Result) > 0 {
		job.Result = op.Result
	}
	job.WorkerID = nil
	job.Hostname = nil
	job.LeaseExpiresAt = nil

	jobData, _ := encodeJobDoc(job)
	batch.Set(kv.JobKey(op.JobID), jobData, f.writeOpts)
	batch.Delete(kv.ActiveKey(job.Queue, op.JobID), f.writeOpts)

	// Clean unique lock
	if job.UniqueKey != nil {
		batch.Delete(kv.UniqueKey(job.Queue, *job.UniqueKey), f.writeOpts)
	}

	// Update batch counter
	var callbackJobID string
	if job.BatchID != nil {
		callbackJobID = f.updateBatchPebble(batch, *job.BatchID, "success", op.NowNs)
	}
	if err := f.appendLifecycleEvent(batch, "completed", op.JobID, job.Queue, op.NowNs); err != nil {
		return &store.OpResult{Err: err}
	}
	if err := f.appendLifecycleCursor(batch); err != nil {
		return &store.OpResult{Err: err}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit ack: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteAckJob(db, job, op, callbackJobID)
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

	if err := batch.Commit(f.writeOpts); err != nil {
		return &store.OpResult{Err: fmt.Errorf("pebble commit fail: %w", err)}
	}

	f.syncSQLite(func(db sqlExecer) error {
		return sqliteFailJob(db, job, op, errDoc, callbackJobID)
	})

	return &store.OpResult{Data: &result}
}

// --- Heartbeat ---

func (f *FSM) applyHeartbeat(data json.RawMessage) *store.OpResult {
	var op store.HeartbeatOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}

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

	jobVal, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("job %q not found", op.JobID)}
	}
	var job store.Job
	if err := decodeJobDoc(jobVal, &job); err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode job %q: %w", op.JobID, err)}
	}
	closer.Close()

	if job.State != store.StateDead && job.State != store.StateCancelled && job.State != store.StateCompleted {
		return &store.OpResult{Err: fmt.Errorf("job %q cannot be retried from state %q", op.JobID, job.State)}
	}

	batch := f.pebble.NewBatch()
	defer batch.Close()

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

// --- DeleteJob ---

func (f *FSM) applyDeleteJob(data json.RawMessage) *store.OpResult {
	var op store.DeleteJobOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}

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
	return f.setQueuePaused(op.Queue, true)
}

func (f *FSM) applyResumeQueue(data json.RawMessage) *store.OpResult {
	var op store.QueueOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: err}
	}
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

	batch := f.pebble.NewBatch()
	defer batch.Close()

	// Delete all jobs in all states
	f.deleteJobsByPrefix(batch, kv.PendingPrefix(op.Queue))
	f.deleteJobsByPrefix(batch, kv.ActivePrefix(op.Queue))
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
			batch.Delete(entry.key, f.writeOpts)
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

	batch := f.pebble.NewBatch()
	defer batch.Close()

	var affected int

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
			if job.State != store.StateDead && job.State != store.StateCancelled && job.State != store.StateCompleted {
				continue
			}
			removeFromSortedSet(batch, f.pebble, job, f.writeOpts)
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
			removeFromSortedSet(batch, f.pebble, job, f.writeOpts)
			batch.Delete(kv.JobKey(jobID), f.writeOpts)
			deletePrefix(batch, f.pebble, kv.JobErrorPrefix(jobID), f.writeOpts)
			affected++

		case "cancel":
			if job.State != store.StatePending && job.State != store.StateActive &&
				job.State != store.StateScheduled && job.State != store.StateRetrying {
				continue
			}
			removeFromSortedSet(batch, f.pebble, job, f.writeOpts)
			job.State = store.StateCancelled
			jobData, _ := encodeJobDoc(job)
			batch.Set(kv.JobKey(jobID), jobData, f.writeOpts)
			affected++

		case "move":
			removeFromSortedSet(batch, f.pebble, job, f.writeOpts)
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
		Priority:       op.Priority,
		MaxRetries:     op.MaxRetries,
		RetryBackoff:   op.Backoff,
		RetryBaseDelay: op.BaseDelayMs,
		RetryMaxDelay:  op.MaxDelayMs,
		CreatedAt:      op.CreatedAt,
		Tags:           op.Tags,
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
func removeFromSortedSet(batch *pebble.Batch, db *pebble.DB, job store.Job, writeOpts *pebble.WriteOptions) {
	switch job.State {
	case store.StatePending:
		deletePendingOrAppendKey(batch, db, job.Queue, job.ID, writeOpts)
	case store.StateActive:
		batch.Delete(kv.ActiveKey(job.Queue, job.ID), writeOpts)
	case store.StateScheduled:
		deleteScheduledKey(batch, db, job.Queue, job.ID, writeOpts)
	case store.StateRetrying:
		deleteRetryingKey(batch, db, job.Queue, job.ID, writeOpts)
	}
}
