package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// EnqueueRequest contains all parameters for enqueuing a job.
type EnqueueRequest struct {
	Queue          string          `json:"queue"`
	Payload        json.RawMessage `json:"payload"`
	Checkpoint     json.RawMessage `json:"checkpoint,omitempty"`
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
	Agent          *AgentConfig    `json:"agent,omitempty"`
	ParentID       string          `json:"parent_id,omitempty"`
	ChainID        string          `json:"chain_id,omitempty"`
	ChainStep      *int            `json:"chain_step,omitempty"`
	ChainConfig    json.RawMessage `json:"chain_config,omitempty"`
	DependsOn      []string         `json:"depends_on,omitempty"`
	Chain          *ChainDefinition `json:"chain,omitempty"`
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

	// Validate and set up chain if provided.
	var chainID string
	var chainStep *int
	var chainConfig json.RawMessage
	if req.Chain != nil {
		if len(req.Chain.Steps) < 2 {
			return nil, fmt.Errorf("chain requires at least 2 steps")
		}
		if req.Chain.Steps[0].Queue != req.Queue {
			return nil, fmt.Errorf("first chain step queue %q must match enqueue queue %q", req.Chain.Steps[0].Queue, req.Queue)
		}
		for i, step := range req.Chain.Steps {
			if step.Queue == "" {
				return nil, fmt.Errorf("chain step %d has empty queue", i)
			}
		}
		if req.Chain.OnFailure != nil && req.Chain.OnFailure.Queue == "" {
			return nil, fmt.Errorf("chain on_failure has empty queue")
		}
		if req.Chain.OnExit != nil && req.Chain.OnExit.Queue == "" {
			return nil, fmt.Errorf("chain on_exit has empty queue")
		}
		chainID = NewChainID()
		step0 := 0
		chainStep = &step0
		chainConfig, _ = json.Marshal(req.Chain)
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

	// If chain is set, use generated chain fields; otherwise use raw request fields.
	opChainID := req.ChainID
	opChainStep := req.ChainStep
	opChainConfig := mergeDependsOnChainConfig(req.ChainConfig, req.DependsOn)
	if req.Chain != nil {
		opChainID = chainID
		opChainStep = chainStep
		opChainConfig = chainConfig
	}

	op := EnqueueOp{
		JobID:        jobID,
		Queue:        req.Queue,
		State:        state,
		Payload:      req.Payload,
		Checkpoint:   req.Checkpoint,
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
		Agent:        normalizeAgentConfig(req.Agent),
		ParentID:     req.ParentID,
		ChainID:      opChainID,
		ChainStep:    opChainStep,
		ChainConfig:  opChainConfig,
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
			JobID:        NewJobID(),
			Queue:        jobReq.Queue,
			State:        StatePending,
			Payload:      jobReq.Payload,
			Checkpoint:   jobReq.Checkpoint,
			Priority:     priority,
			MaxRetries:   maxRetries,
			Backoff:      backoff,
			BaseDelayMs:  baseDelayMs,
			MaxDelayMs:   maxDelayMs,
			Tags:         jobReq.Tags,
			CreatedAt:    now.UTC(),
			NowNs:        uint64(now.UnixNano()),
			Agent:        normalizeAgentConfig(jobReq.Agent),
			ParentID:     jobReq.ParentID,
			ChainID:      jobReq.ChainID,
			ChainStep:    jobReq.ChainStep,
			ChainConfig:  mergeDependsOnChainConfig(jobReq.ChainConfig, jobReq.DependsOn),
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

func mergeDependsOnChainConfig(chainCfg json.RawMessage, dependsOn []string) json.RawMessage {
	if len(dependsOn) == 0 {
		return chainCfg
	}
	uniq := make([]string, 0, len(dependsOn))
	seen := map[string]struct{}{}
	for _, id := range dependsOn {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		uniq = append(uniq, id)
	}
	if len(uniq) == 0 {
		return chainCfg
	}
	cfg := map[string]any{}
	if len(chainCfg) > 0 {
		_ = json.Unmarshal(chainCfg, &cfg)
	}
	cfg["depends_on"] = uniq
	out, _ := json.Marshal(cfg)
	return out
}

func normalizeAgentConfig(cfg *AgentConfig) *AgentState {
	if cfg == nil {
		return nil
	}
	out := &AgentState{
		MaxIterations:    cfg.MaxIterations,
		MaxCostUSD:       cfg.MaxCostUSD,
		IterationTimeout: cfg.IterationTimeout,
		Iteration:        1,
	}
	if out.MaxIterations < 0 {
		out.MaxIterations = 0
	}
	if out.MaxCostUSD < 0 {
		out.MaxCostUSD = 0
	}
	return out
}

