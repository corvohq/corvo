package store

import (
	"database/sql"
	"fmt"
	"time"
)

// ListQueues returns all queues with live job counts from local SQLite.
func (s *Store) ListQueues() ([]QueueInfo, error) {
	rows, err := s.sqliteR.Query(`
		WITH all_queues AS (
			SELECT DISTINCT queue AS name FROM jobs
			UNION
			SELECT name FROM queues
		)
		SELECT
			aq.name, COALESCE(q.paused, 0), q.max_concurrency, q.rate_limit, q.rate_window_ms, q.provider,
			COALESCE(SUM(CASE WHEN j.state = 'pending' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'active' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'held' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'completed' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'dead' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'scheduled' THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN j.state = 'retrying' THEN 1 ELSE 0 END), 0),
			COUNT(j.id),
			MIN(CASE WHEN j.state = 'pending' THEN j.created_at END)
		FROM all_queues aq
		LEFT JOIN queues q ON q.name = aq.name
		LEFT JOIN jobs j ON j.queue = aq.name
		GROUP BY aq.name
		ORDER BY aq.name
	`)
	if err != nil {
		return nil, fmt.Errorf("list queues: %w", err)
	}
	defer rows.Close()

	var queues []QueueInfo
	for rows.Next() {
		var qi QueueInfo
		var maxConc, rateLimit, rateWindow sql.NullInt64
		var provider sql.NullString
		var oldestPending sql.NullString
		err := rows.Scan(
			&qi.Name, &qi.Paused, &maxConc, &rateLimit, &rateWindow, &provider,
			&qi.Pending, &qi.Active, &qi.Held, &qi.Completed, &qi.Dead, &qi.Scheduled, &qi.Retrying,
			&qi.Enqueued,
			&oldestPending,
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
		_ = provider // removed feature, column kept for compat
		if oldestPending.Valid {
			if t, err := time.Parse(time.RFC3339Nano, oldestPending.String); err == nil {
				qi.OldestPendingAt = &t
			} else if t, err := time.Parse("2006-01-02 15:04:05", oldestPending.String); err == nil {
				qi.OldestPendingAt = &t
			}
		}
		queues = append(queues, qi)
	}
	return queues, rows.Err()
}

// PauseQueue pauses a queue via Raft.
func (s *Store) PauseQueue(name string) error {
	op := QueueOp{Queue: name}
	res := s.applyOp(OpPauseQueue, op)
	return res.Err
}

// ResumeQueue resumes a paused queue via Raft.
func (s *Store) ResumeQueue(name string) error {
	op := QueueOp{Queue: name}
	res := s.applyOp(OpResumeQueue, op)
	return res.Err
}

// ClearQueue deletes all pending and scheduled jobs in a queue via Raft.
func (s *Store) ClearQueue(name string) error {
	op := QueueOp{Queue: name}
	res := s.applyOp(OpClearQueue, op)
	return res.Err
}

// DrainQueue pauses the queue (no new jobs fetched) and lets active jobs finish.
func (s *Store) DrainQueue(name string) error {
	return s.PauseQueue(name)
}

// DeleteQueue deletes a queue and all its jobs via Raft.
func (s *Store) DeleteQueue(name string) error {
	op := QueueOp{Queue: name}
	res := s.applyOp(OpDeleteQueue, op)
	return res.Err
}

// SetConcurrency sets the max global concurrency for a queue via Raft.
func (s *Store) SetConcurrency(name string, max int) error {
	op := SetConcurrencyOp{
		Queue: name,
		Max:   max,
	}
	res := s.applyOp(OpSetConcurrency, op)
	return res.Err
}

// SetThrottle sets the rate limit for a queue via Raft.
func (s *Store) SetThrottle(name string, rate int, windowMs int) error {
	op := SetThrottleOp{
		Queue:    name,
		Rate:     rate,
		WindowMs: windowMs,
	}
	res := s.applyOp(OpSetThrottle, op)
	return res.Err
}

// RemoveThrottle removes the rate limit from a queue via Raft.
func (s *Store) RemoveThrottle(name string) error {
	op := QueueOp{Queue: name}
	res := s.applyOp(OpRemoveThrottle, op)
	return res.Err
}
