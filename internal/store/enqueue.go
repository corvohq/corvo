package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// EnqueueRequest contains all parameters for enqueuing a job.
type EnqueueRequest struct {
	Queue          string          `json:"queue"`
	Payload        json.RawMessage `json:"payload"`
	Priority       string          `json:"priority"`
	UniqueKey      string          `json:"unique_key,omitempty"`
	UniquePeriod   int             `json:"unique_period,omitempty"` // seconds
	MaxRetries     *int            `json:"max_retries,omitempty"`
	RetryBackoff   string          `json:"retry_backoff,omitempty"`
	RetryBaseDelay string          `json:"retry_base_delay,omitempty"` // e.g. "5s"
	RetryMaxDelay  string          `json:"retry_max_delay,omitempty"`  // e.g. "10m"
	ScheduledAt    *time.Time      `json:"scheduled_at,omitempty"`
	ExpireAfter    string          `json:"expire_after,omitempty"` // e.g. "1h"
	Tags           json.RawMessage `json:"tags,omitempty"`
}

// EnqueueResult is the response from enqueuing a job.
type EnqueueResult struct {
	JobID          string `json:"job_id"`
	Status         string `json:"status"`
	UniqueExisting bool   `json:"unique_existing"`
}

// Enqueue inserts a new job into the store.
func (s *Store) Enqueue(req EnqueueRequest) (*EnqueueResult, error) {
	jobID := NewJobID()
	priority := PriorityFromString(req.Priority)

	maxRetries := 3
	if req.MaxRetries != nil {
		maxRetries = *req.MaxRetries
	}

	backoff := BackoffExponential
	if req.RetryBackoff != "" {
		backoff = req.RetryBackoff
	}

	baseDelayMs := 5000
	if req.RetryBaseDelay != "" {
		if d, err := time.ParseDuration(req.RetryBaseDelay); err == nil {
			baseDelayMs = int(d.Milliseconds())
		}
	}

	maxDelayMs := 600000
	if req.RetryMaxDelay != "" {
		if d, err := time.ParseDuration(req.RetryMaxDelay); err == nil {
			maxDelayMs = int(d.Milliseconds())
		}
	}

	state := StatePending
	var scheduledAt *string
	if req.ScheduledAt != nil {
		state = StateScheduled
		sa := req.ScheduledAt.UTC().Format(time.RFC3339Nano)
		scheduledAt = &sa
	}

	var expireAt *string
	if req.ExpireAfter != "" {
		if d, err := time.ParseDuration(req.ExpireAfter); err == nil {
			t := time.Now().Add(d).UTC().Format(time.RFC3339Nano)
			expireAt = &t
		}
	}

	var tags *string
	if len(req.Tags) > 0 {
		ts := string(req.Tags)
		tags = &ts
	}

	var uniqueKey *string
	if req.UniqueKey != "" {
		uniqueKey = &req.UniqueKey
	}

	result := &EnqueueResult{JobID: jobID, Status: state}

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		// Check unique lock if unique_key is set
		if uniqueKey != nil {
			var existingJobID string
			err := tx.Stmt(s.stmtCheckUnique).QueryRow(req.Queue, *uniqueKey).Scan(&existingJobID)
			if err == nil {
				// Lock exists — return existing job
				result.JobID = existingJobID
				result.UniqueExisting = true
				result.Status = "duplicate"
				return nil
			}
			if err != sql.ErrNoRows {
				return fmt.Errorf("check unique lock: %w", err)
			}

			// Insert unique lock
			period := 3600 // default 1 hour
			if req.UniquePeriod > 0 {
				period = req.UniquePeriod
			}
			_, err = tx.Stmt(s.stmtInsertUnique).Exec(req.Queue, *uniqueKey, jobID, period)
			if err != nil {
				return fmt.Errorf("insert unique lock: %w", err)
			}
		}

		// Insert job (prepared statement)
		_, err := tx.Stmt(s.stmtInsertJob).Exec(
			jobID, req.Queue, state, string(req.Payload), priority,
			maxRetries, backoff, baseDelayMs, maxDelayMs,
			uniqueKey, tags, scheduledAt, expireAt,
		)
		if err != nil {
			return fmt.Errorf("insert job: %w", err)
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	// Async: ensure queue exists, emit event and stats (non-critical)
	if !result.UniqueExisting {
		s.async.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", req.Queue)
		s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('enqueued', ?, ?)", jobID, req.Queue)
		s.async.Emit("INSERT INTO queue_stats (queue, enqueued) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET enqueued = enqueued + 1", req.Queue)
	}

	return result, nil
}

// BatchEnqueueRequest contains parameters for batch enqueue.
type BatchEnqueueRequest struct {
	Jobs  []EnqueueRequest `json:"jobs"`
	Batch *BatchConfig     `json:"batch,omitempty"`
}

// BatchConfig configures batch completion callback.
type BatchConfig struct {
	CallbackQueue   string          `json:"callback_queue"`
	CallbackPayload json.RawMessage `json:"callback_payload,omitempty"`
}

// BatchEnqueueResult is the response from a batch enqueue.
type BatchEnqueueResult struct {
	JobIDs  []string `json:"job_ids"`
	BatchID string   `json:"batch_id,omitempty"`
}

// EnqueueBatch inserts multiple jobs and optionally creates a batch row.
func (s *Store) EnqueueBatch(req BatchEnqueueRequest) (*BatchEnqueueResult, error) {
	var batchID string
	if req.Batch != nil {
		batchID = NewBatchID()
	}

	jobIDs := make([]string, len(req.Jobs))
	for i := range req.Jobs {
		jobIDs[i] = NewJobID()
	}

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		// Create batch row if configured
		if req.Batch != nil {
			var callbackPayload *string
			if len(req.Batch.CallbackPayload) > 0 {
				cp := string(req.Batch.CallbackPayload)
				callbackPayload = &cp
			}
			_, err := tx.Exec(
				`INSERT INTO batches (id, total, pending, callback_queue, callback_payload) VALUES (?, ?, ?, ?, ?)`,
				batchID, len(req.Jobs), len(req.Jobs), req.Batch.CallbackQueue, callbackPayload,
			)
			if err != nil {
				return fmt.Errorf("insert batch: %w", err)
			}
		}

		for i, jobReq := range req.Jobs {
			priority := PriorityFromString(jobReq.Priority)
			maxRetries := 3
			if jobReq.MaxRetries != nil {
				maxRetries = *jobReq.MaxRetries
			}
			backoff := BackoffExponential
			if jobReq.RetryBackoff != "" {
				backoff = jobReq.RetryBackoff
			}
			baseDelayMs := 5000
			if jobReq.RetryBaseDelay != "" {
				if d, err := time.ParseDuration(jobReq.RetryBaseDelay); err == nil {
					baseDelayMs = int(d.Milliseconds())
				}
			}
			maxDelayMs := 600000
			if jobReq.RetryMaxDelay != "" {
				if d, err := time.ParseDuration(jobReq.RetryMaxDelay); err == nil {
					maxDelayMs = int(d.Milliseconds())
				}
			}

			var tags *string
			if len(jobReq.Tags) > 0 {
				ts := string(jobReq.Tags)
				tags = &ts
			}

			var batchIDPtr *string
			if batchID != "" {
				batchIDPtr = &batchID
			}

			_, err := tx.Exec(
				`INSERT INTO jobs (id, queue, state, payload, priority, max_retries, retry_backoff, retry_base_delay_ms, retry_max_delay_ms, tags, batch_id) VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?)`,
				jobIDs[i], jobReq.Queue, string(jobReq.Payload), priority,
				maxRetries, backoff, baseDelayMs, maxDelayMs,
				tags, batchIDPtr,
			)
			if err != nil {
				return fmt.Errorf("insert job %d: %w", i, err)
			}
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	// Async: ensure queues exist, emit events and stats (non-critical)
	for i, jobReq := range req.Jobs {
		s.async.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", jobReq.Queue)
		s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('enqueued', ?, ?)", jobIDs[i], jobReq.Queue)
		s.async.Emit("INSERT INTO queue_stats (queue, enqueued) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET enqueued = enqueued + 1", jobReq.Queue)
	}

	return &BatchEnqueueResult{JobIDs: jobIDs, BatchID: batchID}, nil
}
