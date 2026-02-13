package store

import (
	"time"
)

// FailResult is the response from failing a job.
type FailResult struct {
	Status            string     `json:"status"` // "retrying" or "dead"
	NextAttemptAt     *time.Time `json:"next_attempt_at,omitempty"`
	AttemptsRemaining int        `json:"attempts_remaining"`
}

// Fail records a job failure via Raft consensus.
func (s *Store) Fail(jobID string, errMsg string, backtrace string) (*FailResult, error) {
	now := time.Now()
	op := FailOp{
		JobID:     jobID,
		Error:     errMsg,
		Backtrace: backtrace,
		NowNs:     uint64(now.UnixNano()),
	}

	return applyOpResult[FailResult](s, OpFail, op)
}
