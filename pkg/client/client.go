package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client is a thin HTTP wrapper for the Jobbie API.
type Client struct {
	URL        string
	HTTPClient *http.Client
}

// New creates a new Jobbie client.
func New(url string) *Client {
	return &Client{
		URL: url,
		HTTPClient: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

// EnqueueOption configures an enqueue request.
type EnqueueOption func(map[string]interface{})

type AgentConfig struct {
	MaxIterations    int     `json:"max_iterations,omitempty"`
	MaxCostUSD       float64 `json:"max_cost_usd,omitempty"`
	IterationTimeout string  `json:"iteration_timeout,omitempty"`
}

type AgentState struct {
	MaxIterations    int     `json:"max_iterations,omitempty"`
	MaxCostUSD       float64 `json:"max_cost_usd,omitempty"`
	IterationTimeout string  `json:"iteration_timeout,omitempty"`
	Iteration        int     `json:"iteration,omitempty"`
	TotalCostUSD     float64 `json:"total_cost_usd,omitempty"`
}

func WithPriority(p string) EnqueueOption {
	return func(m map[string]interface{}) { m["priority"] = p }
}

func WithUniqueKey(key string, period int) EnqueueOption {
	return func(m map[string]interface{}) {
		m["unique_key"] = key
		if period > 0 {
			m["unique_period"] = period
		}
	}
}

func WithMaxRetries(n int) EnqueueOption {
	return func(m map[string]interface{}) { m["max_retries"] = n }
}

func WithScheduledAt(t time.Time) EnqueueOption {
	return func(m map[string]interface{}) { m["scheduled_at"] = t.Format(time.RFC3339) }
}

func WithTags(tags map[string]string) EnqueueOption {
	return func(m map[string]interface{}) { m["tags"] = tags }
}

func WithExpireAfter(d time.Duration) EnqueueOption {
	return func(m map[string]interface{}) { m["expire_after"] = d.String() }
}

func WithRetryBackoff(strategy, baseDelay, maxDelay string) EnqueueOption {
	return func(m map[string]interface{}) {
		m["retry_backoff"] = strategy
		m["retry_base_delay"] = baseDelay
		m["retry_max_delay"] = maxDelay
	}
}

func WithAgent(cfg AgentConfig) EnqueueOption {
	return func(m map[string]interface{}) { m["agent"] = cfg }
}

// EnqueueResult is the response from enqueuing a job.
type EnqueueResult struct {
	JobID          string `json:"job_id"`
	Status         string `json:"status"`
	UniqueExisting bool   `json:"unique_existing"`
}

// Enqueue enqueues a job.
func (c *Client) Enqueue(queue string, payload interface{}, opts ...EnqueueOption) (*EnqueueResult, error) {
	body := map[string]interface{}{
		"queue":   queue,
		"payload": payload,
	}
	for _, opt := range opts {
		opt(body)
	}

	var result EnqueueResult
	if err := c.post("/api/v1/enqueue", body, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

// BatchRequest is the request for batch enqueue.
type BatchRequest struct {
	Jobs  []BatchJob   `json:"jobs"`
	Batch *BatchConfig `json:"batch,omitempty"`
}

// BatchJob is a single job in a batch.
type BatchJob struct {
	Queue   string      `json:"queue"`
	Payload interface{} `json:"payload"`
}

// BatchConfig configures batch completion callback.
type BatchConfig struct {
	CallbackQueue   string      `json:"callback_queue"`
	CallbackPayload interface{} `json:"callback_payload,omitempty"`
}

// BatchResult is the response from batch enqueue.
type BatchResult struct {
	JobIDs  []string `json:"job_ids"`
	BatchID string   `json:"batch_id"`
}

// EnqueueBatch enqueues multiple jobs.
func (c *Client) EnqueueBatch(req BatchRequest) (*BatchResult, error) {
	var result BatchResult
	if err := c.post("/api/v1/enqueue/batch", req, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

// Job is a job returned from the API.
type Job struct {
	ID          string          `json:"id"`
	Queue       string          `json:"queue"`
	State       string          `json:"state"`
	Payload     json.RawMessage `json:"payload"`
	Priority    int             `json:"priority"`
	Attempt     int             `json:"attempt"`
	MaxRetries  int             `json:"max_retries"`
	Tags        json.RawMessage `json:"tags,omitempty"`
	Checkpoint  json.RawMessage `json:"checkpoint,omitempty"`
	Agent       *AgentState     `json:"agent,omitempty"`
	HoldReason  *string         `json:"hold_reason,omitempty"`
	CreatedAt   string          `json:"created_at"`
	StartedAt   *string         `json:"started_at,omitempty"`
	CompletedAt *string         `json:"completed_at,omitempty"`
}

// GetJob returns a job by ID.
func (c *Client) GetJob(id string) (*Job, error) {
	var job Job
	if err := c.get("/api/v1/jobs/"+id, &job); err != nil {
		return nil, err
	}
	return &job, nil
}

// SearchFilter matches the server search filter.
type SearchFilter struct {
	Queue           string            `json:"queue,omitempty"`
	State           []string          `json:"state,omitempty"`
	Priority        string            `json:"priority,omitempty"`
	Tags            map[string]string `json:"tags,omitempty"`
	PayloadContains string            `json:"payload_contains,omitempty"`
	ErrorContains   string            `json:"error_contains,omitempty"`
	Sort            string            `json:"sort,omitempty"`
	Order           string            `json:"order,omitempty"`
	Limit           int               `json:"limit,omitempty"`
	Cursor          string            `json:"cursor,omitempty"`
}

// SearchResult is the response from a search.
type SearchResult struct {
	Jobs       []json.RawMessage `json:"jobs"`
	Total      int               `json:"total"`
	Cursor     string            `json:"cursor,omitempty"`
	HasMore    bool              `json:"has_more"`
	DurationMs int64             `json:"duration_ms"`
}

// Search searches for jobs.
func (c *Client) Search(filter SearchFilter) (*SearchResult, error) {
	var result SearchResult
	if err := c.post("/api/v1/jobs/search", filter, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

// Queue management

func (c *Client) ListQueues() (json.RawMessage, error) {
	var result json.RawMessage
	if err := c.get("/api/v1/queues", &result); err != nil {
		return nil, err
	}
	return result, nil
}

func (c *Client) PauseQueue(name string) error {
	return c.post("/api/v1/queues/"+name+"/pause", nil, nil)
}

func (c *Client) ResumeQueue(name string) error {
	return c.post("/api/v1/queues/"+name+"/resume", nil, nil)
}

func (c *Client) RetryJob(id string) error {
	return c.post("/api/v1/jobs/"+id+"/retry", nil, nil)
}

func (c *Client) CancelJob(id string) error {
	return c.post("/api/v1/jobs/"+id+"/cancel", nil, nil)
}

func (c *Client) DeleteJob(id string) error {
	return c.doRequest("DELETE", "/api/v1/jobs/"+id, nil, nil)
}

// HTTP helpers

func (c *Client) get(path string, result interface{}) error {
	return c.doRequest("GET", path, nil, result)
}

func (c *Client) post(path string, body interface{}, result interface{}) error {
	return c.doRequest("POST", path, body, result)
}

func (c *Client) postWithContext(ctx context.Context, path string, body interface{}, result interface{}) error {
	return c.doRequestWithContext(ctx, "POST", path, body, result)
}

func (c *Client) doRequest(method, path string, body interface{}, result interface{}) error {
	return c.doRequestWithContext(context.Background(), method, path, body, result)
}

func (c *Client) doRequestWithContext(ctx context.Context, method, path string, body interface{}, result interface{}) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshal body: %w", err)
		}
		reader = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.URL+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	if resp.StatusCode >= 400 {
		var apiErr struct {
			Error string `json:"error"`
			Code  string `json:"code"`
		}
		json.Unmarshal(data, &apiErr)
		return fmt.Errorf("%s: %s", apiErr.Code, apiErr.Error)
	}

	if result != nil {
		return json.Unmarshal(data, result)
	}
	return nil
}
