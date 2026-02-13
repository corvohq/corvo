package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type AckRequest struct {
	JobID       string
	Result      json.RawMessage
	Checkpoint  json.RawMessage
	Trace       json.RawMessage
	Usage       *UsageReport
	AgentStatus string
	HoldReason  string
}

// Ack marks a job as completed via Raft consensus.
func (s *Store) Ack(jobID string, result json.RawMessage) error {
	return s.AckJob(AckRequest{JobID: jobID, Result: result})
}

// AckWithUsage marks a job completed and records optional usage metadata.
func (s *Store) AckWithUsage(jobID string, result json.RawMessage, usage *UsageReport) error {
	return s.AckJob(AckRequest{JobID: jobID, Result: result, Usage: usage})
}

func (s *Store) AckJob(req AckRequest) error {
	if err := s.validateAckResultSchema(req.JobID, req.Result); err != nil {
		return err
	}

	normUsage := normalizeUsage(req.Usage)
	if normUsage != nil {
		exceeded, action, err := s.evaluatePerJobBudget(req.JobID, normUsage.CostUSD)
		if err != nil {
			return err
		}
		if exceeded && action == BudgetOnExceedReject {
			return NewBudgetExceededError(fmt.Sprintf("per-job budget exceeded for job %q", req.JobID))
		}
	}

	status := strings.TrimSpace(strings.ToLower(req.AgentStatus))
	switch status {
	case "", AgentStatusContinue, AgentStatusDone, AgentStatusHold:
	default:
		return fmt.Errorf("invalid agent_status %q", req.AgentStatus)
	}

	now := time.Now()
	op := AckOp{
		JobID:       req.JobID,
		Result:      req.Result,
		Checkpoint:  req.Checkpoint,
		Trace:       req.Trace,
		Usage:       normUsage,
		AgentStatus: status,
		HoldReason:  strings.TrimSpace(req.HoldReason),
		NowNs:       uint64(now.UnixNano()),
	}

	res := s.applyOp(OpAck, op)
	return res.Err
}

// AckBatch marks many jobs as completed in one Raft apply.
func (s *Store) AckBatch(acks []AckOp) (int, error) {
	if len(acks) == 0 {
		return 0, nil
	}
	for i := range acks {
		if err := s.validateAckResultSchema(acks[i].JobID, acks[i].Result); err != nil {
			return 0, err
		}
		acks[i].Usage = normalizeUsage(acks[i].Usage)
		if acks[i].Usage == nil {
			continue
		}
		exceeded, action, err := s.evaluatePerJobBudget(acks[i].JobID, acks[i].Usage.CostUSD)
		if err != nil {
			return 0, err
		}
		if exceeded && action == BudgetOnExceedReject {
			return 0, NewBudgetExceededError(fmt.Sprintf("per-job budget exceeded for job %q", acks[i].JobID))
		}
	}
	now := uint64(time.Now().UnixNano())
	op := AckBatchOp{
		Acks:  acks,
		NowNs: now,
	}
	res := s.applyOp(OpAckBatch, op)
	if res.Err != nil {
		return 0, res.Err
	}
	n, ok := res.Data.(int)
	if !ok {
		return 0, fmt.Errorf("unexpected ack batch result type: %T", res.Data)
	}
	return n, nil
}
