package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// GetJob returns a job with its error history.
func (s *Store) GetJob(id string) (*Job, error) {
	var j Job
	var payload, tags, progress, checkpoint, result sql.NullString
	var uniqueKey, batchID, workerID, hostname sql.NullString
	var leaseExpiresAt, scheduledAt, expireAt, startedAt, completedAt, failedAt sql.NullString
	var createdAt string
	var paused int

	err := s.db.Read.QueryRow(`
		SELECT id, queue, state, payload, priority, attempt, max_retries,
			retry_backoff, retry_base_delay_ms, retry_max_delay_ms,
			unique_key, batch_id, worker_id, hostname,
			tags, progress, checkpoint, result,
			lease_expires_at, scheduled_at, expire_at,
			created_at, started_at, completed_at, failed_at
		FROM jobs WHERE id = ?
	`, id).Scan(
		&j.ID, &j.Queue, &j.State, &payload, &j.Priority, &j.Attempt, &j.MaxRetries,
		&j.RetryBackoff, &j.RetryBaseDelay, &j.RetryMaxDelay,
		&uniqueKey, &batchID, &workerID, &hostname,
		&tags, &progress, &checkpoint, &result,
		&leaseExpiresAt, &scheduledAt, &expireAt,
		&createdAt, &startedAt, &completedAt, &failedAt,
	)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("job %q not found", id)
	}
	if err != nil {
		return nil, fmt.Errorf("get job: %w", err)
	}

	_ = paused
	j.Payload = json.RawMessage(payload.String)
	setNullableString(&j.UniqueKey, uniqueKey)
	setNullableString(&j.BatchID, batchID)
	setNullableString(&j.WorkerID, workerID)
	setNullableString(&j.Hostname, hostname)
	if tags.Valid {
		j.Tags = json.RawMessage(tags.String)
	}
	if progress.Valid {
		j.Progress = json.RawMessage(progress.String)
	}
	if checkpoint.Valid {
		j.Checkpoint = json.RawMessage(checkpoint.String)
	}
	if result.Valid {
		j.Result = json.RawMessage(result.String)
	}
	j.CreatedAt = parseTime(createdAt)
	j.LeaseExpiresAt = parseNullableTime(leaseExpiresAt)
	j.ScheduledAt = parseNullableTime(scheduledAt)
	j.ExpireAt = parseNullableTime(expireAt)
	j.StartedAt = parseNullableTime(startedAt)
	j.CompletedAt = parseNullableTime(completedAt)
	j.FailedAt = parseNullableTime(failedAt)

	// Load errors
	rows, err := s.db.Read.Query(
		"SELECT id, job_id, attempt, error, backtrace, created_at FROM job_errors WHERE job_id = ? ORDER BY attempt",
		id,
	)
	if err != nil {
		return nil, fmt.Errorf("query job errors: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var je JobError
		var bt sql.NullString
		var cat string
		if err := rows.Scan(&je.ID, &je.JobID, &je.Attempt, &je.Error, &bt, &cat); err != nil {
			return nil, fmt.Errorf("scan job error: %w", err)
		}
		if bt.Valid {
			je.Backtrace = &bt.String
		}
		je.CreatedAt = parseTime(cat)
		j.Errors = append(j.Errors, je)
	}

	return &j, rows.Err()
}

// RetryJob resets a dead/cancelled/completed job back to pending.
func (s *Store) RetryJob(id string) error {
	var queue string

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		var state string
		err := tx.QueryRow("SELECT state, queue FROM jobs WHERE id = ?", id).Scan(&state, &queue)
		if err == sql.ErrNoRows {
			return fmt.Errorf("job %q not found", id)
		}
		if err != nil {
			return err
		}

		if state != StateDead && state != StateCancelled && state != StateCompleted {
			return fmt.Errorf("job %q cannot be retried from state %q", id, state)
		}

		_, err = tx.Exec(`
			UPDATE jobs SET
				state = 'pending',
				attempt = 0,
				failed_at = NULL,
				completed_at = NULL,
				worker_id = NULL,
				hostname = NULL,
				lease_expires_at = NULL,
				scheduled_at = NULL
			WHERE id = ?
		`, id)
		if err != nil {
			return fmt.Errorf("retry job: %w", err)
		}

		return nil
	})

	if err != nil {
		return err
	}

	// Async: emit event (non-critical)
	s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('retried', ?, ?)", id, queue)
	return nil
}

// CancelJob cancels a pending/scheduled job or marks an active job for cancellation.
func (s *Store) CancelJob(id string) (string, error) {
	var resultStatus string
	var queue string

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		var state string
		err := tx.QueryRow("SELECT state, queue FROM jobs WHERE id = ?", id).Scan(&state, &queue)
		if err == sql.ErrNoRows {
			return fmt.Errorf("job %q not found", id)
		}
		if err != nil {
			return err
		}

		switch state {
		case StatePending, StateScheduled, StateRetrying:
			_, err = tx.Exec("UPDATE jobs SET state = 'cancelled' WHERE id = ?", id)
			resultStatus = StateCancelled
		case StateActive:
			// Mark as cancelled — worker will see this on next heartbeat
			_, err = tx.Exec("UPDATE jobs SET state = 'cancelled' WHERE id = ?", id)
			resultStatus = "cancelling"
		default:
			return fmt.Errorf("job %q cannot be cancelled from state %q", id, state)
		}
		if err != nil {
			return fmt.Errorf("cancel job: %w", err)
		}

		return nil
	})

	if err != nil {
		return "", err
	}

	// Async: emit event (non-critical)
	s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('cancelled', ?, ?)", id, queue)
	return resultStatus, err
}

// MoveJob moves a job to a different queue.
func (s *Store) MoveJob(id, targetQueue string) error {
	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		res, err := tx.Exec("UPDATE jobs SET queue = ? WHERE id = ?", targetQueue, id)
		if err != nil {
			return fmt.Errorf("move job: %w", err)
		}
		affected, _ := res.RowsAffected()
		if affected == 0 {
			return fmt.Errorf("job %q not found", id)
		}

		return nil
	})

	if err != nil {
		return err
	}

	// Async: ensure target queue exists, emit event (non-critical)
	s.async.Emit("INSERT OR IGNORE INTO queues (name) VALUES (?)", targetQueue)
	s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('moved', ?, ?)", id, targetQueue)
	return nil
}

// DeleteJob permanently removes a job.
func (s *Store) DeleteJob(id string) error {
	res, err := s.writer.Execute("DELETE FROM jobs WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("delete job: %w", err)
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return fmt.Errorf("job %q not found", id)
	}
	return nil
}

func setNullableString(target **string, src sql.NullString) {
	if src.Valid {
		*target = &src.String
	}
}

func parseTime(s string) time.Time {
	for _, layout := range []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05.000",
		"2006-01-02T15:04:05",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

func parseNullableTime(s sql.NullString) *time.Time {
	if !s.Valid {
		return nil
	}
	t := parseTime(s.String)
	if t.IsZero() {
		return nil
	}
	return &t
}
