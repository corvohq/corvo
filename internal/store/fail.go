package store

import (
	"database/sql"
	"fmt"
	"time"
)

// FailResult is the response from failing a job.
type FailResult struct {
	Status            string     `json:"status"` // "retrying" or "dead"
	NextAttemptAt     *time.Time `json:"next_attempt_at,omitempty"`
	AttemptsRemaining int        `json:"attempts_remaining"`
}

// Fail records a job failure, calculates backoff, and transitions state.
func (s *Store) Fail(jobID string, errMsg string, backtrace string) (*FailResult, error) {
	var result FailResult
	var queue string
	var eventType string

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		// Read current job state
		var state, retryBackoff string
		var attempt, maxRetries, baseDelayMs, maxDelayMs int
		var batchID sql.NullString
		err := tx.QueryRow(`
			SELECT queue, state, attempt, max_retries, retry_backoff, retry_base_delay_ms, retry_max_delay_ms, batch_id
			FROM jobs WHERE id = ?
		`, jobID).Scan(&queue, &state, &attempt, &maxRetries, &retryBackoff, &baseDelayMs, &maxDelayMs, &batchID)
		if err == sql.ErrNoRows {
			return fmt.Errorf("job %s not found", jobID)
		}
		if err != nil {
			return fmt.Errorf("read job: %w", err)
		}
		if state != StateActive {
			return fmt.Errorf("job %s is not active (state=%s)", jobID, state)
		}

		now := time.Now().UTC()

		// Insert error record
		var backtracePtr *string
		if backtrace != "" {
			backtracePtr = &backtrace
		}
		_, err = tx.Exec(
			`INSERT INTO job_errors (job_id, attempt, error, backtrace) VALUES (?, ?, ?, ?)`,
			jobID, attempt, errMsg, backtracePtr,
		)
		if err != nil {
			return fmt.Errorf("insert job error: %w", err)
		}

		remaining := maxRetries - attempt
		if remaining < 0 {
			remaining = 0
		}

		if remaining > 0 {
			// Retry: calculate backoff delay
			delay := CalculateBackoff(retryBackoff, attempt, baseDelayMs, maxDelayMs)
			nextAttempt := now.Add(delay)
			scheduledAt := nextAttempt.Format(time.RFC3339Nano)
			failedAt := now.Format(time.RFC3339Nano)

			_, err = tx.Exec(`
				UPDATE jobs SET
					state = 'retrying',
					failed_at = ?,
					scheduled_at = ?,
					worker_id = NULL,
					hostname = NULL,
					lease_expires_at = NULL
				WHERE id = ?
			`, failedAt, scheduledAt, jobID)
			if err != nil {
				return fmt.Errorf("update job to retrying: %w", err)
			}

			result.Status = StateRetrying
			result.NextAttemptAt = &nextAttempt
			result.AttemptsRemaining = remaining
			eventType = "failed"
		} else {
			// Dead: all retries exhausted
			failedAt := now.Format(time.RFC3339Nano)

			_, err = tx.Exec(`
				UPDATE jobs SET
					state = 'dead',
					failed_at = ?,
					worker_id = NULL,
					hostname = NULL,
					lease_expires_at = NULL
				WHERE id = ?
			`, failedAt, jobID)
			if err != nil {
				return fmt.Errorf("update job to dead: %w", err)
			}

			result.Status = StateDead
			result.AttemptsRemaining = 0
			eventType = "dead"

			// Update batch counter for failure
			if batchID.Valid {
				if err := s.updateBatchCounter(tx, batchID.String, "failure"); err != nil {
					return err
				}
			}
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	// Async: emit event and stats (non-critical)
	s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES (?, ?, ?)", eventType, jobID, queue)
	if eventType == "failed" {
		s.async.Emit("INSERT INTO queue_stats (queue, failed) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET failed = failed + 1", queue)
	} else {
		s.async.Emit("INSERT INTO queue_stats (queue, dead) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET dead = dead + 1", queue)
	}

	return &result, nil
}
