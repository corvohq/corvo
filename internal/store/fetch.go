package store

import (
	"encoding/json"
	"fmt"
	"strings"
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
	Agent         *AgentState     `json:"agent,omitempty"`
	RoutingTarget *string         `json:"routing_target,omitempty"`
}

// Fetch claims the highest-priority pending job from the given queues via Raft.
// Returns nil if no job is available.
func (s *Store) Fetch(req FetchRequest) (*FetchResult, error) {
	if len(req.Queues) == 0 {
		return nil, fmt.Errorf("at least one queue is required")
	}
	allowedQueues, err := s.enforceFetchBudgets(req.Queues)
	if err != nil {
		return nil, err
	}
	allowedQueues, err = s.enforceFetchProviders(allowedQueues)
	if err != nil {
		return nil, err
	}
	if len(allowedQueues) == 0 {
		return nil, nil
	}

	leaseDuration := req.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}

	now := time.Now()
	op := FetchOp{
		Queues:        allowedQueues,
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

	allowedQueues, err := s.enforceFetchBudgets(req.Queues)
	if err != nil {
		return nil, err
	}
	allowedQueues, err = s.enforceFetchProviders(allowedQueues)
	if err != nil {
		return nil, err
	}
	if len(allowedQueues) == 0 {
		return []FetchResult{}, nil
	}

	leaseDuration := req.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}

	now := time.Now()
	op := FetchBatchOp{
		Queues:        allowedQueues,
		WorkerID:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: leaseDuration,
		Count:         count,
		NowNs:         uint64(now.UnixNano()),
		RandomSeed:    fetchSeedCounter.Add(1),
	}
	if ids, err := s.localPeekPendingCandidates(allowedQueues, count); err == nil && len(ids) > 0 {
		op.CandidateJobIDs = ids
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

// localPeekPendingCandidates uses the local SQLite mirror to find pending jobs
// quickly, then delegates authoritative claim/validation to Raft FSM.
func (s *Store) localPeekPendingCandidates(queues []string, count int) ([]string, error) {
	if s.sqliteR == nil || len(queues) == 0 || count <= 0 {
		return nil, nil
	}
	args := make([]any, 0, len(queues)+1)
	holders := make([]string, 0, len(queues))
	for _, q := range queues {
		if strings.TrimSpace(q) == "" {
			continue
		}
		holders = append(holders, "?")
		args = append(args, q)
	}
	if len(holders) == 0 {
		return nil, nil
	}
	args = append(args, count)
	query := `
		SELECT id
		FROM jobs
		WHERE state = 'pending'
		  AND queue IN (` + strings.Join(holders, ",") + `)
		ORDER BY priority ASC, created_at ASC
		LIMIT ?
	`
	rows, err := s.sqliteR.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0, count)
	seen := make(map[string]struct{}, count)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			continue
		}
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out, nil
}

func marshalQueues(queues []string) string {
	b, _ := json.Marshal(queues)
	return string(b)
}
