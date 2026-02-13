package store

import (
	"encoding/json"
	"fmt"
	"time"
)

// Ack marks a job as completed via Raft consensus.
func (s *Store) Ack(jobID string, result json.RawMessage) error {
	now := time.Now()
	op := AckOp{
		JobID:  jobID,
		Result: result,
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
