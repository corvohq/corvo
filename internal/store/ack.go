package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// Ack marks a job as completed.
func (s *Store) Ack(jobID string, result json.RawMessage) error {
	var queue string

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		now := time.Now().UTC().Format(time.RFC3339Nano)

		var resultStr *string
		if len(result) > 0 {
			rs := string(result)
			resultStr = &rs
		}

		// Mark job completed
		res, err := tx.Exec(`
			UPDATE jobs SET
				state = 'completed',
				completed_at = ?,
				result = ?,
				worker_id = NULL,
				hostname = NULL,
				lease_expires_at = NULL
			WHERE id = ? AND state = 'active'
		`, now, resultStr, jobID)
		if err != nil {
			return fmt.Errorf("update job: %w", err)
		}
		affected, _ := res.RowsAffected()
		if affected == 0 {
			return fmt.Errorf("job %s is not active", jobID)
		}

		// Get queue name for unique lock cleanup + batch logic
		var uniqueKey, batchID sql.NullString
		err = tx.QueryRow("SELECT queue, unique_key, batch_id FROM jobs WHERE id = ?", jobID).
			Scan(&queue, &uniqueKey, &batchID)
		if err != nil {
			return fmt.Errorf("read job: %w", err)
		}

		// Clean unique lock
		if uniqueKey.Valid {
			_, err = tx.Exec("DELETE FROM unique_locks WHERE job_id = ?", jobID)
			if err != nil {
				return fmt.Errorf("delete unique lock: %w", err)
			}
		}

		// Update batch counter
		if batchID.Valid {
			if err := s.updateBatchCounter(tx, batchID.String, "success"); err != nil {
				return err
			}
		}

		return nil
	})

	if err != nil {
		return err
	}

	// Async: emit event and stats (non-critical)
	s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('completed', ?, ?)", jobID, queue)
	s.async.Emit("INSERT INTO queue_stats (queue, completed) VALUES (?, 1) ON CONFLICT(queue) DO UPDATE SET completed = completed + 1", queue)

	return nil
}

func (s *Store) updateBatchCounter(tx *sql.Tx, batchID, outcome string) error {
	var pending int
	var callbackQueue sql.NullString
	var callbackPayload sql.NullString

	var updateCol string
	if outcome == "success" {
		updateCol = "succeeded = succeeded + 1"
	} else {
		updateCol = "failed = failed + 1"
	}

	err := tx.QueryRow(fmt.Sprintf(`
		UPDATE batches SET
			pending = pending - 1,
			%s
		WHERE id = ?
		RETURNING pending, callback_queue, callback_payload
	`, updateCol), batchID).Scan(&pending, &callbackQueue, &callbackPayload)
	if err != nil {
		return fmt.Errorf("update batch counter: %w", err)
	}

	// If all jobs done, enqueue callback
	if pending == 0 && callbackQueue.Valid {
		callbackJobID := NewJobID()
		payload := "{}"
		if callbackPayload.Valid {
			payload = callbackPayload.String
		}
		_, err = tx.Exec(
			`INSERT INTO jobs (id, queue, state, payload, priority) VALUES (?, ?, 'pending', ?, 2)`,
			callbackJobID, callbackQueue.String, payload,
		)
		if err != nil {
			return fmt.Errorf("enqueue batch callback: %w", err)
		}
		_, err = tx.Exec(`INSERT INTO events (type, job_id, queue, data) VALUES ('batch_complete', ?, ?, ?)`,
			callbackJobID, callbackQueue.String, fmt.Sprintf(`{"batch_id":"%s"}`, batchID))
		if err != nil {
			return fmt.Errorf("insert batch event: %w", err)
		}
	}

	return nil
}
