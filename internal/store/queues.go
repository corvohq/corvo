package store

import (
	"database/sql"
	"fmt"
)

// ListQueues returns all queues with live job counts.
func (s *Store) ListQueues() ([]QueueInfo, error) {
	rows, err := s.db.Read.Query(`
		SELECT
			q.name, q.paused, q.max_concurrency, q.rate_limit, q.rate_window_ms, q.created_at,
			COALESCE(qs.enqueued, 0), COALESCE(qs.completed, 0), COALESCE(qs.failed, 0), COALESCE(qs.dead, 0),
			COALESCE(SUM(CASE WHEN j.state = 'pending' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'active' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'completed' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'dead' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'scheduled' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'retrying' THEN 1 ELSE 0 END), 0)
		FROM queues q
		LEFT JOIN queue_stats qs ON qs.queue = q.name
		LEFT JOIN jobs j ON j.queue = q.name
		GROUP BY q.name
		ORDER BY q.name
	`)
	if err != nil {
		return nil, fmt.Errorf("list queues: %w", err)
	}
	defer rows.Close()

	var queues []QueueInfo
	for rows.Next() {
		var qi QueueInfo
		var maxConc, rateLimit, rateWindow sql.NullInt64
		var createdAt string
		err := rows.Scan(
			&qi.Name, &qi.Paused, &maxConc, &rateLimit, &rateWindow, &createdAt,
			&qi.Enqueued, &qi.Failed, &qi.Failed, &qi.Dead,
			&qi.Pending, &qi.Active, &qi.Completed, &qi.Dead, &qi.Scheduled, &qi.Retrying,
		)
		if err != nil {
			return nil, fmt.Errorf("scan queue: %w", err)
		}
		if maxConc.Valid {
			v := int(maxConc.Int64)
			qi.MaxConcurrency = &v
		}
		if rateLimit.Valid {
			v := int(rateLimit.Int64)
			qi.RateLimit = &v
		}
		if rateWindow.Valid {
			v := int(rateWindow.Int64)
			qi.RateWindowMs = &v
		}
		queues = append(queues, qi)
	}
	return queues, rows.Err()
}

// PauseQueue pauses a queue so workers cannot fetch jobs from it.
func (s *Store) PauseQueue(name string) error {
	return s.updateQueueField(name, "paused", 1)
}

// ResumeQueue resumes a paused queue.
func (s *Store) ResumeQueue(name string) error {
	return s.updateQueueField(name, "paused", 0)
}

// ClearQueue deletes all pending and scheduled jobs in a queue.
func (s *Store) ClearQueue(name string) error {
	return s.writer.ExecuteTx(func(tx *sql.Tx) error {
		_, err := tx.Exec("DELETE FROM jobs WHERE queue = ? AND state IN ('pending', 'scheduled')", name)
		if err != nil {
			return fmt.Errorf("clear queue: %w", err)
		}
		_, err = tx.Exec("INSERT INTO events (type, queue) VALUES ('queue_cleared', ?)", name)
		return err
	})
}

// DrainQueue pauses the queue (no new jobs fetched) and lets active jobs finish.
func (s *Store) DrainQueue(name string) error {
	return s.updateQueueField(name, "paused", 1)
}

// DeleteQueue deletes a queue and all its jobs.
func (s *Store) DeleteQueue(name string) error {
	return s.writer.ExecuteTx(func(tx *sql.Tx) error {
		_, err := tx.Exec("DELETE FROM jobs WHERE queue = ?", name)
		if err != nil {
			return fmt.Errorf("delete queue jobs: %w", err)
		}
		_, err = tx.Exec("DELETE FROM queue_stats WHERE queue = ?", name)
		if err != nil {
			return fmt.Errorf("delete queue stats: %w", err)
		}
		_, err = tx.Exec("DELETE FROM rate_limit_window WHERE queue = ?", name)
		if err != nil {
			return fmt.Errorf("delete rate limit entries: %w", err)
		}
		_, err = tx.Exec("DELETE FROM unique_locks WHERE queue = ?", name)
		if err != nil {
			return fmt.Errorf("delete unique locks: %w", err)
		}
		_, err = tx.Exec("DELETE FROM queues WHERE name = ?", name)
		if err != nil {
			return fmt.Errorf("delete queue: %w", err)
		}
		return nil
	})
}

// SetConcurrency sets the max global concurrency for a queue.
func (s *Store) SetConcurrency(name string, max int) error {
	var val interface{} = max
	if max <= 0 {
		val = nil // unlimited
	}
	return s.updateQueueField(name, "max_concurrency", val)
}

// SetThrottle sets the rate limit for a queue.
func (s *Store) SetThrottle(name string, rate int, windowMs int) error {
	_, err := s.writer.Execute(
		"UPDATE queues SET rate_limit = ?, rate_window_ms = ? WHERE name = ?",
		rate, windowMs, name,
	)
	return err
}

// RemoveThrottle removes the rate limit from a queue.
func (s *Store) RemoveThrottle(name string) error {
	_, err := s.writer.Execute(
		"UPDATE queues SET rate_limit = NULL, rate_window_ms = NULL WHERE name = ?",
		name,
	)
	return err
}

func (s *Store) updateQueueField(name, field string, value interface{}) error {
	query := fmt.Sprintf("UPDATE queues SET %s = ? WHERE name = ?", field)
	res, err := s.writer.Execute(query, value, name)
	if err != nil {
		return fmt.Errorf("update queue %s: %w", field, err)
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return fmt.Errorf("queue %q not found", name)
	}
	return nil
}
