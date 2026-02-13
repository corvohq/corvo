package store

import (
	"encoding/json"
	"fmt"
	"sync/atomic"
	"time"
)

var fetchSeedCounter atomic.Uint64

// FetchRequest contains parameters for fetching a job.
type FetchRequest struct {
	Queues        []string `json:"queues"`
	WorkerID      string   `json:"worker_id"`
	Hostname      string   `json:"hostname"`
	LeaseDuration int      `json:"timeout"` // seconds, default 60
}

// FetchResult is the response from fetching a job.
type FetchResult struct {
	JobID         string          `json:"job_id"`
	Queue         string          `json:"queue"`
	Payload       json.RawMessage `json:"payload"`
	Attempt       int             `json:"attempt"`
	MaxRetries    int             `json:"max_retries"`
	LeaseDuration int             `json:"lease_duration"`
	Checkpoint    json.RawMessage `json:"checkpoint,omitempty"`
	Tags          json.RawMessage `json:"tags,omitempty"`
}

// Fetch claims the highest-priority pending job from the given queues via Raft.
// Returns nil if no job is available.
func (s *Store) Fetch(req FetchRequest) (*FetchResult, error) {
	if len(req.Queues) == 0 {
		return nil, fmt.Errorf("at least one queue is required")
	}

	leaseDuration := req.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}

	now := time.Now()
	op := FetchOp{
		Queues:        req.Queues,
		WorkerID:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: leaseDuration,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    fetchSeedCounter.Add(1),
	}

	return applyOpResult[FetchResult](s, OpFetch, op)
}

// FetchBatch claims up to count jobs in one Raft apply.
func (s *Store) FetchBatch(req FetchRequest, count int) ([]FetchResult, error) {
	if len(req.Queues) == 0 {
		return nil, fmt.Errorf("at least one queue is required")
	}
	if count <= 0 {
		return []FetchResult{}, nil
	}

	leaseDuration := req.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}

	now := time.Now()
	op := FetchBatchOp{
		Queues:        req.Queues,
		WorkerID:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: leaseDuration,
		Count:         count,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    fetchSeedCounter.Add(1),
	}

	result := s.applyOp(OpFetchBatch, op)
	if result.Err != nil {
		return nil, result.Err
	}
	if result.Data == nil {
		return []FetchResult{}, nil
	}
	jobs, ok := result.Data.([]FetchResult)
	if !ok {
		return nil, fmt.Errorf("unexpected fetch batch result type: %T", result.Data)
	}
	return jobs, nil
}

func marshalQueues(queues []string) string {
	b, _ := json.Marshal(queues)
	return string(b)
}
