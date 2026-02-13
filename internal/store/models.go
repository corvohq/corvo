package store

import (
	"encoding/json"
	"time"
)

// Job states
const (
	StatePending   = "pending"
	StateActive    = "active"
	StateHeld      = "held"
	StateCompleted = "completed"
	StateRetrying  = "retrying"
	StateDead      = "dead"
	StateCancelled = "cancelled"
	StateScheduled = "scheduled"
)

// Agent statuses reported on ack for iterative workloads.
const (
	AgentStatusContinue = "continue"
	AgentStatusDone     = "done"
	AgentStatusHold     = "hold"
)

// Priority levels (lower = higher priority)
const (
	PriorityCritical = 0
	PriorityHigh     = 1
	PriorityNormal   = 2
)

// Backoff strategies
const (
	BackoffNone        = "none"
	BackoffFixed       = "fixed"
	BackoffLinear      = "linear"
	BackoffExponential = "exponential"
)

// PriorityFromString converts a string priority name to its integer value.
func PriorityFromString(s string) int {
	switch s {
	case "critical":
		return PriorityCritical
	case "high":
		return PriorityHigh
	default:
		return PriorityNormal
	}
}

// PriorityToString converts an integer priority to its string name.
func PriorityToString(p int) string {
	switch p {
	case PriorityCritical:
		return "critical"
	case PriorityHigh:
		return "high"
	default:
		return "normal"
	}
}

// Job represents a job in the system.
type Job struct {
	ID             string          `json:"id"`
	Queue          string          `json:"queue"`
	State          string          `json:"state"`
	Payload        json.RawMessage `json:"payload"`
	Priority       int             `json:"priority"`
	Attempt        int             `json:"attempt"`
	MaxRetries     int             `json:"max_retries"`
	RetryBackoff   string          `json:"retry_backoff"`
	RetryBaseDelay int             `json:"retry_base_delay_ms"`
	RetryMaxDelay  int             `json:"retry_max_delay_ms"`
	UniqueKey      *string         `json:"unique_key,omitempty"`
	BatchID        *string         `json:"batch_id,omitempty"`
	WorkerID       *string         `json:"worker_id,omitempty"`
	Hostname       *string         `json:"hostname,omitempty"`
	Tags           json.RawMessage `json:"tags,omitempty"`
	Progress       json.RawMessage `json:"progress,omitempty"`
	Checkpoint     json.RawMessage `json:"checkpoint,omitempty"`
	Result         json.RawMessage `json:"result,omitempty"`
	ResultSchema   json.RawMessage `json:"result_schema,omitempty"`
	LeaseExpiresAt *time.Time      `json:"lease_expires_at,omitempty"`
	ScheduledAt    *time.Time      `json:"scheduled_at,omitempty"`
	ExpireAt       *time.Time      `json:"expire_at,omitempty"`
	ParentID       *string         `json:"parent_id,omitempty"`
	ChainID        *string         `json:"chain_id,omitempty"`
	ChainStep      *int            `json:"chain_step,omitempty"`
	ChainConfig    json.RawMessage `json:"chain_config,omitempty"`
	ProviderError  bool            `json:"provider_error,omitempty"`
	Routing        *RoutingConfig  `json:"routing,omitempty"`
	RoutingTarget  *string         `json:"routing_target,omitempty"`
	RoutingIndex   int             `json:"routing_index,omitempty"`
	CreatedAt      time.Time       `json:"created_at"`
	StartedAt      *time.Time      `json:"started_at,omitempty"`
	CompletedAt    *time.Time      `json:"completed_at,omitempty"`
	FailedAt       *time.Time      `json:"failed_at,omitempty"`
	Errors         []JobError      `json:"errors,omitempty"`
	Agent          *AgentState     `json:"agent,omitempty"`
	HoldReason     *string         `json:"hold_reason,omitempty"`
}

// JobError represents a single failed attempt for a job.
type JobError struct {
	ID        int       `json:"id"`
	JobID     string    `json:"job_id"`
	Attempt   int       `json:"attempt"`
	Error     string    `json:"error"`
	Backtrace *string   `json:"backtrace,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// Queue represents queue configuration.
type Queue struct {
	Name           string    `json:"name"`
	Paused         bool      `json:"paused"`
	MaxConcurrency *int      `json:"max_concurrency,omitempty"`
	RateLimit      *int      `json:"rate_limit,omitempty"`
	RateWindowMs   *int      `json:"rate_window_ms,omitempty"`
	Provider       *string   `json:"provider,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
}

// QueueInfo is a queue plus live job counts.
type QueueInfo struct {
	Queue
	Pending         int        `json:"pending"`
	Active          int        `json:"active"`
	Held            int        `json:"held"`
	Completed       int        `json:"completed"`
	Dead            int        `json:"dead"`
	Scheduled       int        `json:"scheduled"`
	Retrying        int        `json:"retrying"`
	Enqueued        int        `json:"enqueued"`
	Failed          int        `json:"failed"`
	OldestPendingAt *time.Time `json:"oldest_pending_at,omitempty"`
}

// Batch represents a group of jobs with an optional completion callback.
type Batch struct {
	ID              string          `json:"id"`
	Total           int             `json:"total"`
	Pending         int             `json:"pending"`
	Succeeded       int             `json:"succeeded"`
	Failed          int             `json:"failed"`
	CallbackQueue   *string         `json:"callback_queue,omitempty"`
	CallbackPayload json.RawMessage `json:"callback_payload,omitempty"`
	CreatedAt       time.Time       `json:"created_at"`
}

// Schedule represents a cron schedule for recurring jobs.
type Schedule struct {
	ID         string          `json:"id"`
	Name       string          `json:"name"`
	Queue      string          `json:"queue"`
	Cron       string          `json:"cron"`
	Timezone   string          `json:"timezone"`
	Payload    json.RawMessage `json:"payload"`
	UniqueKey  *string         `json:"unique_key,omitempty"`
	MaxRetries int             `json:"max_retries"`
	LastRun    *time.Time      `json:"last_run,omitempty"`
	NextRun    *time.Time      `json:"next_run,omitempty"`
	CreatedAt  time.Time       `json:"created_at"`
}

// Worker represents a connected worker.
type Worker struct {
	ID            string          `json:"id"`
	Hostname      *string         `json:"hostname,omitempty"`
	Queues        json.RawMessage `json:"queues,omitempty"`
	LastHeartbeat time.Time       `json:"last_heartbeat"`
	StartedAt     time.Time       `json:"started_at"`
}

// Event represents a lifecycle event.
type Event struct {
	ID        int             `json:"id"`
	Type      string          `json:"type"`
	JobID     *string         `json:"job_id,omitempty"`
	Queue     *string         `json:"queue,omitempty"`
	Data      json.RawMessage `json:"data,omitempty"`
	CreatedAt time.Time       `json:"created_at"`
}

type AgentConfig struct {
	MaxIterations    int     `json:"max_iterations,omitempty"`
	MaxCostUSD       float64 `json:"max_cost_usd,omitempty"`
	IterationTimeout string  `json:"iteration_timeout,omitempty"`
}

type RoutingConfig struct {
	Prefer   string   `json:"prefer,omitempty"`
	Fallback []string `json:"fallback,omitempty"`
	Strategy string   `json:"strategy,omitempty"`
}

type AgentState struct {
	MaxIterations    int     `json:"max_iterations,omitempty"`
	MaxCostUSD       float64 `json:"max_cost_usd,omitempty"`
	IterationTimeout string  `json:"iteration_timeout,omitempty"`
	Iteration        int     `json:"iteration,omitempty"`
	TotalCostUSD     float64 `json:"total_cost_usd,omitempty"`
}

type JobIteration struct {
	ID                  int             `json:"id"`
	JobID               string          `json:"job_id"`
	Iteration           int             `json:"iteration"`
	Status              string          `json:"status"`
	Checkpoint          json.RawMessage `json:"checkpoint,omitempty"`
	Trace               json.RawMessage `json:"trace,omitempty"`
	HoldReason          *string         `json:"hold_reason,omitempty"`
	Result              json.RawMessage `json:"result,omitempty"`
	InputTokens         int64           `json:"input_tokens,omitempty"`
	OutputTokens        int64           `json:"output_tokens,omitempty"`
	CacheCreationTokens int64           `json:"cache_creation_tokens,omitempty"`
	CacheReadTokens     int64           `json:"cache_read_tokens,omitempty"`
	Model               *string         `json:"model,omitempty"`
	Provider            *string         `json:"provider,omitempty"`
	CostUSD             float64         `json:"cost_usd,omitempty"`
	CreatedAt           time.Time       `json:"created_at"`
}
