package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

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

// Fetch claims the highest-priority pending job from the given queues.
// Returns nil if no job is available.
func (s *Store) Fetch(req FetchRequest) (*FetchResult, error) {
	if len(req.Queues) == 0 {
		return nil, fmt.Errorf("at least one queue is required")
	}

	leaseDuration := req.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}

	var result *FetchResult

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		// Build queue placeholders
		placeholders := make([]string, len(req.Queues))
		args := make([]interface{}, len(req.Queues))
		for i, q := range req.Queues {
			placeholders[i] = "?"
			args[i] = q
		}
		queueList := strings.Join(placeholders, ", ")

		// Find the highest-priority pending job in unpaused queues,
		// respecting concurrency limits. Uses LEFT JOIN because
		// queue rows are created asynchronously and may not exist yet.
		query := fmt.Sprintf(`
			SELECT j.id, j.queue FROM jobs j
			LEFT JOIN queues q ON q.name = j.queue
			WHERE j.queue IN (%s)
			  AND j.state = 'pending'
			  AND (q.paused IS NULL OR q.paused = 0)
			  AND (q.max_concurrency IS NULL OR (
			    SELECT COUNT(*) FROM jobs j2 WHERE j2.queue = j.queue AND j2.state = 'active'
			  ) < q.max_concurrency)
			ORDER BY j.priority ASC, j.created_at ASC
			LIMIT 1
		`, queueList)

		var jobID, queueName string
		err := tx.QueryRow(query, args...).Scan(&jobID, &queueName)
		if err == sql.ErrNoRows {
			return nil // no job available
		}
		if err != nil {
			return fmt.Errorf("find pending job: %w", err)
		}

		// Check rate limit (pass queue directly, no extra query)
		rateLimited, err := s.checkRateLimit(tx, queueName)
		if err != nil {
			return fmt.Errorf("check rate limit: %w", err)
		}
		if rateLimited {
			return nil
		}

		// Claim the job
		now := time.Now().UTC()
		leaseExpires := now.Add(time.Duration(leaseDuration) * time.Second).Format(time.RFC3339Nano)
		startedAt := now.Format(time.RFC3339Nano)

		_, err = tx.Exec(`
			UPDATE jobs SET
				state = 'active',
				worker_id = ?,
				hostname = ?,
				started_at = ?,
				lease_expires_at = ?,
				attempt = attempt + 1
			WHERE id = ?
		`, req.WorkerID, req.Hostname, startedAt, leaseExpires, jobID)
		if err != nil {
			return fmt.Errorf("claim job: %w", err)
		}

		// Record rate limit entry (use queue from initial query)
		_, err = tx.Exec(`INSERT INTO rate_limit_window (queue, fetched_at) VALUES (?, ?)`,
			queueName, startedAt)
		if err != nil {
			return fmt.Errorf("record rate limit: %w", err)
		}

		// Update/insert worker record
		_, err = tx.Exec(`
			INSERT INTO workers (id, hostname, queues, last_heartbeat, started_at)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(id) DO UPDATE SET
				hostname = excluded.hostname,
				queues = excluded.queues,
				last_heartbeat = excluded.last_heartbeat
		`, req.WorkerID, req.Hostname, marshalQueues(req.Queues), startedAt, startedAt)
		if err != nil {
			return fmt.Errorf("upsert worker: %w", err)
		}

		// Read back the full job for the response
		var payload, tags, checkpoint sql.NullString
		var attempt, maxRetries int
		err = tx.QueryRow(`SELECT payload, attempt, max_retries, tags, checkpoint FROM jobs WHERE id = ?`, jobID).
			Scan(&payload, &attempt, &maxRetries, &tags, &checkpoint)
		if err != nil {
			return fmt.Errorf("read claimed job: %w", err)
		}

		result = &FetchResult{
			JobID:         jobID,
			Queue:         queueName,
			Payload:       json.RawMessage(payload.String),
			Attempt:       attempt,
			MaxRetries:    maxRetries,
			LeaseDuration: leaseDuration,
		}
		if tags.Valid {
			result.Tags = json.RawMessage(tags.String)
		}
		if checkpoint.Valid {
			result.Checkpoint = json.RawMessage(checkpoint.String)
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	// Async: emit event after transaction succeeds (non-critical)
	if result != nil {
		s.async.Emit("INSERT INTO events (type, job_id, queue) VALUES ('started', ?, ?)", result.JobID, result.Queue)
	}

	return result, nil
}

func (s *Store) checkRateLimit(tx *sql.Tx, queue string) (bool, error) {
	var rateLimit, rateWindowMs sql.NullInt64
	err := tx.QueryRow("SELECT rate_limit, rate_window_ms FROM queues WHERE name = ?", queue).
		Scan(&rateLimit, &rateWindowMs)
	if err != nil || !rateLimit.Valid || !rateWindowMs.Valid {
		return false, nil // no rate limit configured
	}

	windowSeconds := float64(rateWindowMs.Int64) / 1000.0
	var count int
	err = tx.QueryRow(`
		SELECT COUNT(*) FROM rate_limit_window
		WHERE queue = ? AND fetched_at > strftime('%Y-%m-%dT%H:%M:%f', 'now', '-' || ? || ' seconds')
	`, queue, windowSeconds).Scan(&count)
	if err != nil {
		return false, err
	}

	return int64(count) >= rateLimit.Int64, nil
}

func marshalQueues(queues []string) string {
	b, _ := json.Marshal(queues)
	return string(b)
}
