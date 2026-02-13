package store

import (
	"encoding/json"
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

// Enqueue inserts a new job into the store via Raft consensus.
func (s *Store) Enqueue(req EnqueueRequest) (*EnqueueResult, error) {
	now := time.Now()
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
	if req.ScheduledAt != nil {
		state = StateScheduled
	}

	var expireAt *time.Time
	if req.ExpireAfter != "" {
		if d, err := time.ParseDuration(req.ExpireAfter); err == nil {
			t := now.Add(d).UTC()
			expireAt = &t
		}
	}

	op := EnqueueOp{
		JobID:        jobID,
		Queue:        req.Queue,
		State:        state,
		Payload:      req.Payload,
		Priority:     priority,
		MaxRetries:   maxRetries,
		Backoff:      backoff,
		BaseDelayMs:  baseDelayMs,
		MaxDelayMs:   maxDelayMs,
		UniqueKey:    req.UniqueKey,
		UniquePeriod: req.UniquePeriod,
		Tags:         req.Tags,
		ScheduledAt:  req.ScheduledAt,
		ExpireAt:     expireAt,
		CreatedAt:    now.UTC(),
		NowNs:        uint64(now.UnixNano()),
	}

	return applyOpResult[EnqueueResult](s, OpEnqueue, op)
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

// EnqueueBatch inserts multiple jobs via Raft.
func (s *Store) EnqueueBatch(req BatchEnqueueRequest) (*BatchEnqueueResult, error) {
	now := time.Now()
	var batchID string
	if req.Batch != nil {
		batchID = NewBatchID()
	}

	jobs := make([]EnqueueOp, len(req.Jobs))
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

		jobs[i] = EnqueueOp{
			JobID:       NewJobID(),
			Queue:       jobReq.Queue,
			State:       StatePending,
			Payload:     jobReq.Payload,
			Priority:    priority,
			MaxRetries:  maxRetries,
			Backoff:     backoff,
			BaseDelayMs: baseDelayMs,
			MaxDelayMs:  maxDelayMs,
			Tags:        jobReq.Tags,
			CreatedAt:   now.UTC(),
			NowNs:       uint64(now.UnixNano()),
		}
	}

	var batchOp *BatchOp
	if req.Batch != nil {
		batchOp = &BatchOp{
			CallbackQueue:   req.Batch.CallbackQueue,
			CallbackPayload: req.Batch.CallbackPayload,
		}
	}

	op := EnqueueBatchOp{
		Jobs:    jobs,
		BatchID: batchID,
		Batch:   batchOp,
	}

	return applyOpResult[BatchEnqueueResult](s, OpEnqueueBatch, op)
}
