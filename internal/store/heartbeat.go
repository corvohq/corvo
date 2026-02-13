package store

import (
	"encoding/json"
	"time"
)

// HeartbeatJobUpdate contains per-job heartbeat data.
type HeartbeatJobUpdate struct {
	Progress    map[string]interface{} `json:"progress,omitempty"`
	Checkpoint  map[string]interface{} `json:"checkpoint,omitempty"`
	StreamDelta string                 `json:"stream_delta,omitempty"`
	Usage       *UsageReport           `json:"usage,omitempty"`
}

// HeartbeatRequest contains the batched heartbeat data for all active jobs on a worker.
type HeartbeatRequest struct {
	Jobs map[string]HeartbeatJobUpdate `json:"jobs"`
}

// HeartbeatJobResponse is the per-job heartbeat response.
type HeartbeatJobResponse struct {
	Status         string `json:"status"`                    // "ok" or "cancel"
	BudgetExceeded bool   `json:"budget_exceeded,omitempty"` // soft signal to wrap up
}

// HeartbeatResponse is the batched heartbeat response.
type HeartbeatResponse struct {
	Jobs map[string]HeartbeatJobResponse `json:"jobs"`
}

// Heartbeat extends leases and updates progress/checkpoint via Raft consensus.
func (s *Store) Heartbeat(req HeartbeatRequest) (*HeartbeatResponse, error) {
	now := time.Now()

	jobs := make(map[string]HeartbeatJobOp, len(req.Jobs))
	for jobID, update := range req.Jobs {
		var progress, checkpoint json.RawMessage
		if update.Progress != nil {
			progress, _ = json.Marshal(update.Progress)
		}
		if update.Checkpoint != nil {
			checkpoint, _ = json.Marshal(update.Checkpoint)
		}
		jobs[jobID] = HeartbeatJobOp{
			Progress:    progress,
			Checkpoint:  checkpoint,
			StreamDelta: update.StreamDelta,
			Usage:       normalizeUsage(update.Usage),
		}
	}

	op := HeartbeatOp{
		Jobs:  jobs,
		NowNs: uint64(now.UnixNano()),
	}

	resp, err := applyOpResult[HeartbeatResponse](s, OpHeartbeat, op)
	if err != nil || resp == nil {
		return resp, err
	}
	for jobID, update := range req.Jobs {
		incomingCost := 0.0
		if n := normalizeUsage(update.Usage); n != nil {
			incomingCost = n.CostUSD
		}
		exceeded, action, berr := s.evaluatePerJobBudget(jobID, incomingCost)
		if berr != nil || !exceeded {
			continue
		}
		jr := resp.Jobs[jobID]
		jr.BudgetExceeded = true
		resp.Jobs[jobID] = jr
		switch action {
		case BudgetOnExceedHold:
			_ = s.HoldJob(jobID)
		case BudgetOnExceedReject:
			_, _ = s.CancelJob(jobID)
		}
	}
	return resp, nil
}
