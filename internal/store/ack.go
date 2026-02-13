package store

import (
	"encoding/json"
	"fmt"
	"time"
)

// Ack marks a job as completed via Raft consensus.
func (s *Store) Ack(jobID string, result json.RawMessage) error {
	return s.AckWithUsage(jobID, result, nil)
}

// AckWithUsage marks a job completed and records optional usage metadata.
func (s *Store) AckWithUsage(jobID string, result json.RawMessage, usage *UsageReport) error {
	now := time.Now()
	op := AckOp{
		JobID:  jobID,
		Result: result,
		Usage:  normalizeUsage(usage),
		NowNs:  uint64(now.UnixNano()),
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
		acks[i].Usage = normalizeUsage(acks[i].Usage)
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
