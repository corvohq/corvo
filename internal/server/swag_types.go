package server

import (
	"encoding/json"

	"github.com/corvohq/corvo/internal/store"
)

// ErrorResponse is the standard API error response shape.
type ErrorResponse struct {
	Error string `json:"error"`
	Code  string `json:"code"`
}

// StatusResponse is a generic status response.
type StatusResponse struct {
	Status string `json:"status"`
}

// FetchBatchRequest is the request body for POST /fetch/batch.
type FetchBatchRequest struct {
	Queues        []string `json:"queues"`
	WorkerID      string   `json:"worker_id"`
	Hostname      string   `json:"hostname"`
	LeaseDuration int      `json:"timeout"`
	Count         int      `json:"count"`
}

// FetchBatchResponse is the response for POST /fetch/batch.
type FetchBatchResponse struct {
	Jobs []store.FetchResult `json:"jobs"`
}

// AckBody is the request body for POST /ack/{job_id}.
type AckBody struct {
	Result      json.RawMessage    `json:"result"`
	Checkpoint  json.RawMessage    `json:"checkpoint"`
	Usage       *store.UsageReport `json:"usage"`
	AgentStatus string             `json:"agent_status"`
	HoldReason  string             `json:"hold_reason"`
	StepStatus  string             `json:"step_status"`
	ExitReason  string             `json:"exit_reason"`
}

// AckBatchItem is a single ack entry in an ack batch.
type AckBatchItem struct {
	JobID  string             `json:"job_id"`
	Result json.RawMessage    `json:"result"`
	Usage  *store.UsageReport `json:"usage"`
}

// AckBatchRequest is the request body for POST /ack/batch.
type AckBatchRequest struct {
	Acks []AckBatchItem `json:"acks"`
}

// AckedCountResponse is the response for POST /ack/batch.
type AckedCountResponse struct {
	Acked int `json:"acked"`
}

// FailBody is the request body for POST /fail/{job_id}.
type FailBody struct {
	Error     string `json:"error"`
	Backtrace string `json:"backtrace"`
}

// SetConcurrencyRequest is the request body for POST /queues/{name}/concurrency.
type SetConcurrencyRequest struct {
	Max int `json:"max"`
}

// SetThrottleRequest is the request body for POST /queues/{name}/throttle.
type SetThrottleRequest struct {
	Rate     int `json:"rate"`
	WindowMs int `json:"window_ms"`
}

// MoveJobRequest is the request body for POST /jobs/{id}/move.
type MoveJobRequest struct {
	Queue string `json:"queue"`
}

// ReplayJobRequest is the request body for POST /jobs/{id}/replay.
type ReplayJobRequest struct {
	From int `json:"from"`
}

// SetAPIKeyRequest is the request body for POST /auth/keys.
type SetAPIKeyRequest struct {
	Name       string `json:"name"`
	Key        string `json:"key,omitempty"`
	Namespace  string `json:"namespace,omitempty"`
	Role       string `json:"role,omitempty"`
	QueueScope string `json:"queue_scope,omitempty"`
	ExpiresAt  string `json:"expires_at,omitempty"`
	Enabled    *bool  `json:"enabled,omitempty"`
}

// SetAPIKeyResponse is the response for POST /auth/keys.
type SetAPIKeyResponse struct {
	Status string `json:"status"`
	APIKey string `json:"api_key"`
}

// DeleteAPIKeyRequest is the request body for DELETE /auth/keys.
type DeleteAPIKeyRequest struct {
	KeyHash string `json:"key_hash"`
}

// BulkWithAsyncRequest wraps BulkRequest with an optional async flag.
type BulkWithAsyncRequest struct {
	store.BulkRequest
	Async *bool `json:"async,omitempty"`
}

// BulkAsyncAcceptedResponse is returned when a bulk operation is accepted asynchronously.
type BulkAsyncAcceptedResponse struct {
	BulkOperationID string `json:"bulk_operation_id"`
	Status          string `json:"status"`
	EstimatedTotal  int    `json:"estimated_total"`
	ProgressURL     string `json:"progress_url"`
}

// IterationsResponse is the response for GET /jobs/{id}/iterations.
type IterationsResponse struct {
	Iterations []store.JobIteration `json:"iterations"`
}
