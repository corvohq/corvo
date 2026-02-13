package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/user/jobbie/internal/kv"
	"github.com/user/jobbie/internal/store"
)

// sqlExecer abstracts *sql.DB and *sql.Tx.
type sqlExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

func sqliteInsertJob(db sqlExecer, op store.EnqueueOp) error {
	var scheduledAt, expireAt, tags, uniqueKey *string
	if op.ScheduledAt != nil {
		s := op.ScheduledAt.UTC().Format(time.RFC3339Nano)
		scheduledAt = &s
	}
	if op.ExpireAt != nil {
		s := op.ExpireAt.UTC().Format(time.RFC3339Nano)
		expireAt = &s
	}
	if len(op.Tags) > 0 {
		s := string(op.Tags)
		tags = &s
	}
	if op.UniqueKey != "" {
		uniqueKey = &op.UniqueKey
	}

	createdAt := op.CreatedAt.UTC().Format(time.RFC3339Nano)

	_, err := db.Exec(`INSERT OR REPLACE INTO jobs (id, queue, state, payload, priority, max_retries,
		retry_backoff, retry_base_delay_ms, retry_max_delay_ms, unique_key, tags, scheduled_at, expire_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		op.JobID, op.Queue, op.State, string(op.Payload), op.Priority,
		op.MaxRetries, op.Backoff, op.BaseDelayMs, op.MaxDelayMs,
		uniqueKey, tags, scheduledAt, expireAt, createdAt,
	)
	if err != nil {
		return fmt.Errorf("sqlite insert job: %w", err)
	}

	// Ensure queue exists
	db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", op.Queue)

	// Insert unique lock if needed
	if op.UniqueKey != "" {
		period := op.UniquePeriod
		if period <= 0 {
			period = 3600
		}
		expiresAt := time.Unix(0, int64(op.NowNs)).Add(time.Duration(period) * time.Second).UTC().Format(time.RFC3339Nano)
		db.Exec("INSERT OR REPLACE INTO unique_locks (queue, unique_key, job_id, expires_at) VALUES (?, ?, ?, ?)",
			op.Queue, op.UniqueKey, op.JobID, expiresAt)
	}

	return nil
}

func sqliteInsertBatch(db sqlExecer, op store.EnqueueBatchOp) error {
	// Create batch record
	if op.BatchID != "" && op.Batch != nil {
		var callbackPayload *string
		if len(op.Batch.CallbackPayload) > 0 {
			s := string(op.Batch.CallbackPayload)
			callbackPayload = &s
		}
		db.Exec(`INSERT OR REPLACE INTO batches (id, total, pending, callback_queue, callback_payload) VALUES (?, ?, ?, ?, ?)`,
			op.BatchID, len(op.Jobs), len(op.Jobs), op.Batch.CallbackQueue, callbackPayload)
	}

	for _, j := range op.Jobs {
		var tags *string
		if len(j.Tags) > 0 {
			s := string(j.Tags)
			tags = &s
		}
		var batchIDPtr *string
		if op.BatchID != "" {
			batchIDPtr = &op.BatchID
		}
		createdAt := j.CreatedAt.UTC().Format(time.RFC3339Nano)
		db.Exec(`INSERT OR REPLACE INTO jobs (id, queue, state, payload, priority, max_retries,
			retry_backoff, retry_base_delay_ms, retry_max_delay_ms, tags, batch_id, created_at)
			VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			j.JobID, j.Queue, string(j.Payload), j.Priority,
			j.MaxRetries, j.Backoff, j.BaseDelayMs, j.MaxDelayMs,
			tags, batchIDPtr, createdAt,
		)
		db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", j.Queue)
	}
	return nil
}

func sqliteFetchJob(db sqlExecer, job store.Job, op store.FetchOp) error {
	now := time.Unix(0, int64(op.NowNs))
	leaseDuration := op.LeaseDuration
	if leaseDuration <= 0 {
		leaseDuration = 60
	}
	leaseExpires := now.Add(time.Duration(leaseDuration) * time.Second).UTC().Format(time.RFC3339Nano)
	startedAt := now.UTC().Format(time.RFC3339Nano)

	_, err := db.Exec(`UPDATE jobs SET state = 'active', worker_id = ?, hostname = ?,
		started_at = ?, lease_expires_at = ?, attempt = ? WHERE id = ?`,
		op.WorkerID, op.Hostname, startedAt, leaseExpires, job.Attempt, job.ID)
	if err != nil {
		return err
	}

	// Record rate limit entry
	db.Exec("INSERT INTO rate_limit_window (queue, fetched_at) VALUES (?, ?)", job.Queue, startedAt)

	// Upsert worker
	queuesJSON, _ := json.Marshal(op.Queues)
	db.Exec(`INSERT INTO workers (id, hostname, queues, last_heartbeat, started_at)
		VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
		hostname = excluded.hostname, queues = excluded.queues, last_heartbeat = excluded.last_heartbeat`,
		op.WorkerID, op.Hostname, string(queuesJSON), startedAt, startedAt)

	return nil
}

func sqliteAckJob(db sqlExecer, job store.Job, op store.AckOp, callbackJobID string) error {
	now := time.Unix(0, int64(op.NowNs)).UTC().Format(time.RFC3339Nano)
	var resultStr *string
	if len(op.Result) > 0 {
		s := string(op.Result)
		resultStr = &s
	}

	_, err := db.Exec(`UPDATE jobs SET state = 'completed', completed_at = ?, result = ?,
		worker_id = NULL, hostname = NULL, lease_expires_at = NULL WHERE id = ?`,
		now, resultStr, op.JobID)
	if err != nil {
		return err
	}

	// Clean unique lock
	if job.UniqueKey != nil {
		db.Exec("DELETE FROM unique_locks WHERE job_id = ?", op.JobID)
	}

	// Update batch
	if job.BatchID != nil {
		sqliteUpdateBatch(db, *job.BatchID, "success", callbackJobID)
	}

	return nil
}

func sqliteUpdateBatch(db sqlExecer, batchID, outcome, callbackJobID string) {
	var updateCol string
	if outcome == "success" {
		updateCol = "succeeded = succeeded + 1"
	} else {
		updateCol = "failed = failed + 1"
	}
	db.Exec(fmt.Sprintf("UPDATE batches SET pending = pending - 1, %s WHERE id = ?", updateCol), batchID)

	if callbackJobID != "" {
		// The callback job was already inserted by the Pebble side, just insert into SQLite
		db.Exec(`INSERT OR IGNORE INTO jobs (id, queue, state, payload, priority)
			SELECT ?, callback_queue, 'pending', COALESCE(callback_payload, '{}'), 2
			FROM batches WHERE id = ?`, callbackJobID, batchID)
	}
}

func sqliteFailJob(db sqlExecer, job store.Job, op store.FailOp, errDoc store.JobError, callbackJobID string) error {
	now := time.Unix(0, int64(op.NowNs)).UTC().Format(time.RFC3339Nano)

	// Insert error
	var backtrace *string
	if op.Backtrace != "" {
		backtrace = &op.Backtrace
	}
	db.Exec("INSERT INTO job_errors (job_id, attempt, error, backtrace, created_at) VALUES (?, ?, ?, ?, ?)",
		op.JobID, errDoc.Attempt, op.Error, backtrace, now)

	if job.State == store.StateRetrying {
		var scheduledAt *string
		if job.ScheduledAt != nil {
			s := job.ScheduledAt.UTC().Format(time.RFC3339Nano)
			scheduledAt = &s
		}
		_, err := db.Exec(`UPDATE jobs SET state = 'retrying', failed_at = ?, scheduled_at = ?,
			worker_id = NULL, hostname = NULL, lease_expires_at = NULL WHERE id = ?`,
			now, scheduledAt, op.JobID)
		return err
	}

	// Dead
	_, err := db.Exec(`UPDATE jobs SET state = 'dead', failed_at = ?,
		worker_id = NULL, hostname = NULL, lease_expires_at = NULL WHERE id = ?`,
		now, op.JobID)
	if err != nil {
		return err
	}

	if job.BatchID != nil {
		sqliteUpdateBatch(db, *job.BatchID, "failure", callbackJobID)
	}

	return nil
}

func sqliteHeartbeat(db sqlExecer, op store.HeartbeatOp, leaseExp time.Time, workerID string, now time.Time) error {
	leaseStr := leaseExp.UTC().Format(time.RFC3339Nano)
	for jobID, update := range op.Jobs {
		var progressStr, checkpointStr *string
		if len(update.Progress) > 0 {
			s := string(update.Progress)
			progressStr = &s
		}
		if len(update.Checkpoint) > 0 {
			s := string(update.Checkpoint)
			checkpointStr = &s
		}

		if progressStr != nil && checkpointStr != nil {
			db.Exec("UPDATE jobs SET progress = ?, checkpoint = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
				*progressStr, *checkpointStr, leaseStr, jobID)
		} else if progressStr != nil {
			db.Exec("UPDATE jobs SET progress = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
				*progressStr, leaseStr, jobID)
		} else if checkpointStr != nil {
			db.Exec("UPDATE jobs SET checkpoint = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
				*checkpointStr, leaseStr, jobID)
		} else {
			db.Exec("UPDATE jobs SET lease_expires_at = ? WHERE id = ? AND state = 'active'",
				leaseStr, jobID)
		}
	}

	if workerID != "" {
		nowStr := now.UTC().Format(time.RFC3339Nano)
		db.Exec("UPDATE workers SET last_heartbeat = ? WHERE id = ?", nowStr, workerID)
	}

	return nil
}

func sqliteRetryJob(db sqlExecer, jobID string) error {
	_, err := db.Exec(`UPDATE jobs SET state = 'pending', attempt = 0, failed_at = NULL, completed_at = NULL,
		worker_id = NULL, hostname = NULL, lease_expires_at = NULL, scheduled_at = NULL WHERE id = ?`, jobID)
	return err
}

func sqliteCancelJob(db sqlExecer, jobID string) error {
	_, err := db.Exec("UPDATE jobs SET state = 'cancelled' WHERE id = ?", jobID)
	return err
}

func sqliteMoveJob(db sqlExecer, jobID, targetQueue string) error {
	db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", targetQueue)
	_, err := db.Exec("UPDATE jobs SET queue = ? WHERE id = ?", targetQueue, jobID)
	return err
}

func sqliteDeleteJob(db sqlExecer, jobID string) error {
	db.Exec("DELETE FROM job_errors WHERE job_id = ?", jobID)
	_, err := db.Exec("DELETE FROM jobs WHERE id = ?", jobID)
	return err
}

func sqliteUpdateQueueField(db sqlExecer, queue, field string, value any) error {
	db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", queue)
	query := fmt.Sprintf("UPDATE queues SET %s = ? WHERE name = ?", field)
	_, err := db.Exec(query, value, queue)
	return err
}

func sqliteDeleteQueue(db sqlExecer, queue string) error {
	db.Exec("DELETE FROM jobs WHERE queue = ?", queue)
	db.Exec("DELETE FROM rate_limit_window WHERE queue = ?", queue)
	db.Exec("DELETE FROM unique_locks WHERE queue = ?", queue)
	_, err := db.Exec("DELETE FROM queues WHERE name = ?", queue)
	return err
}

func sqliteBulkAction(db sqlExecer, op store.BulkActionOp) error {
	if len(op.JobIDs) == 0 {
		return nil
	}

	placeholders := make([]string, len(op.JobIDs))
	args := make([]any, len(op.JobIDs))
	for i, id := range op.JobIDs {
		placeholders[i] = "?"
		args[i] = id
	}
	inClause := strings.Join(placeholders, ", ")

	switch op.Action {
	case "retry":
		db.Exec(fmt.Sprintf(`UPDATE jobs SET state = 'pending', attempt = 0, failed_at = NULL, completed_at = NULL,
			worker_id = NULL, hostname = NULL, lease_expires_at = NULL, scheduled_at = NULL
			WHERE id IN (%s) AND state IN ('dead', 'cancelled', 'completed')`, inClause), args...)
	case "delete":
		db.Exec(fmt.Sprintf("DELETE FROM job_errors WHERE job_id IN (%s)", inClause), args...)
		db.Exec(fmt.Sprintf("DELETE FROM jobs WHERE id IN (%s)", inClause), args...)
	case "cancel":
		db.Exec(fmt.Sprintf(`UPDATE jobs SET state = 'cancelled'
			WHERE id IN (%s) AND state IN ('pending', 'active', 'scheduled', 'retrying')`, inClause), args...)
	case "move":
		db.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", op.MoveToQueue)
		moveArgs := []any{op.MoveToQueue}
		moveArgs = append(moveArgs, args...)
		db.Exec(fmt.Sprintf("UPDATE jobs SET queue = ? WHERE id IN (%s)", inClause), moveArgs...)
	case "requeue":
		db.Exec(fmt.Sprintf(`UPDATE jobs SET state = 'pending', failed_at = NULL, worker_id = NULL,
			hostname = NULL, lease_expires_at = NULL, scheduled_at = NULL
			WHERE id IN (%s) AND state = 'dead'`, inClause), args...)
	case "change_priority":
		priArgs := []any{op.Priority}
		priArgs = append(priArgs, args...)
		db.Exec(fmt.Sprintf(`UPDATE jobs SET priority = ?
			WHERE id IN (%s) AND state IN ('pending', 'scheduled')`, inClause), priArgs...)
	}
	return nil
}

// RebuildSQLiteFromPebble rebuilds the materialized SQLite view from Pebble.
func (f *FSM) RebuildSQLiteFromPebble() error {
	f.sqliteMu.Lock()
	defer f.sqliteMu.Unlock()

	tx, err := f.sqlite.Begin()
	if err != nil {
		return fmt.Errorf("begin sqlite rebuild tx: %w", err)
	}
	defer tx.Rollback()

	for _, stmt := range []string{
		"DELETE FROM job_errors",
		"DELETE FROM unique_locks",
		"DELETE FROM rate_limit_window",
		"DELETE FROM workers",
		"DELETE FROM schedules",
		"DELETE FROM batches",
		"DELETE FROM jobs",
		"DELETE FROM queues",
	} {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("sqlite rebuild clear (%s): %w", stmt, err)
		}
	}

	queueCfg := make(map[string]store.Queue)
	queueSeen := make(map[string]struct{})

	iter, err := f.pebble.NewIter(nil)
	if err != nil {
		return fmt.Errorf("create pebble iter: %w", err)
	}
	defer iter.Close()

	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		val := iter.Value()
		switch {
		case bytes.HasPrefix(key, []byte(kv.PrefixQueueName)):
			name := string(key[len(kv.PrefixQueueName):])
			if name != "" {
				queueSeen[name] = struct{}{}
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixQueueConfig)):
			name := string(key[len(kv.PrefixQueueConfig):])
			if name == "" {
				continue
			}
			var q store.Queue
			if err := json.Unmarshal(val, &q); err != nil {
				continue
			}
			if q.Name == "" {
				q.Name = name
			}
			queueCfg[name] = q
			queueSeen[name] = struct{}{}
		case bytes.HasPrefix(key, []byte(kv.PrefixJob)):
			var job store.Job
			if err := decodeJobDoc(val, &job); err != nil {
				continue
			}
			if err := sqliteUpsertJobDoc(tx, job); err != nil {
				return err
			}
			if job.Queue != "" {
				queueSeen[job.Queue] = struct{}{}
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixJobError)):
			jobID, attempt, ok := parseJobErrorKey(key)
			if !ok {
				continue
			}
			var doc store.JobError
			if err := json.Unmarshal(val, &doc); err != nil {
				continue
			}
			if doc.JobID == "" {
				doc.JobID = jobID
			}
			if doc.Attempt == 0 {
				doc.Attempt = int(attempt)
			}
			if err := sqliteInsertJobErrorDoc(tx, doc); err != nil {
				return err
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixBatch)):
			var b store.Batch
			if err := json.Unmarshal(val, &b); err != nil {
				continue
			}
			if b.ID == "" {
				b.ID = string(key[len(kv.PrefixBatch):])
			}
			if err := sqliteUpsertBatchDoc(tx, b); err != nil {
				return err
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixWorker)):
			var w store.Worker
			if err := json.Unmarshal(val, &w); err != nil {
				continue
			}
			if w.ID == "" {
				w.ID = string(key[len(kv.PrefixWorker):])
			}
			if err := sqliteUpsertWorkerDoc(tx, w); err != nil {
				return err
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixSchedule)):
			var s store.Schedule
			if err := json.Unmarshal(val, &s); err != nil {
				continue
			}
			if s.ID == "" {
				s.ID = string(key[len(kv.PrefixSchedule):])
			}
			if err := sqliteUpsertScheduleDoc(tx, s); err != nil {
				return err
			}
		case bytes.HasPrefix(key, []byte(kv.PrefixUnique)):
			queue, uniqueKey, ok := parseUniqueKey(key)
			if !ok {
				continue
			}
			jobID, expiresNs := kv.DecodeUniqueValue(val)
			expiresAt := time.Unix(0, int64(expiresNs)).UTC().Format(time.RFC3339Nano)
			if _, err := tx.Exec(
				"INSERT OR REPLACE INTO unique_locks (queue, unique_key, job_id, expires_at) VALUES (?, ?, ?, ?)",
				queue, uniqueKey, jobID, expiresAt,
			); err != nil {
				return fmt.Errorf("upsert unique lock: %w", err)
			}
			queueSeen[queue] = struct{}{}
		case bytes.HasPrefix(key, []byte(kv.PrefixRateLimit)):
			queue, fetchedNs, ok := parseRateLimitKey(key)
			if !ok {
				continue
			}
			fetchedAt := time.Unix(0, int64(fetchedNs)).UTC().Format(time.RFC3339Nano)
			if _, err := tx.Exec(
				"INSERT INTO rate_limit_window (queue, fetched_at) VALUES (?, ?)",
				queue, fetchedAt,
			); err != nil {
				return fmt.Errorf("insert rate limit row: %w", err)
			}
			queueSeen[queue] = struct{}{}
		}
	}
	if err := iter.Error(); err != nil {
		return fmt.Errorf("iterate pebble: %w", err)
	}

	for name := range queueSeen {
		if _, err := tx.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", name); err != nil {
			return fmt.Errorf("insert queue name: %w", err)
		}
	}
	for name, q := range queueCfg {
		if _, err := tx.Exec(
			"UPDATE queues SET paused = ?, max_concurrency = ?, rate_limit = ?, rate_window_ms = ? WHERE name = ?",
			boolToInt(q.Paused), q.MaxConcurrency, q.RateLimit, q.RateWindowMs, name,
		); err != nil {
			return fmt.Errorf("update queue config: %w", err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit sqlite rebuild tx: %w", err)
	}
	return nil
}

func sqliteUpsertJobDoc(db sqlExecer, j store.Job) error {
	var uniqueKey, batchID, workerID, hostname, leaseExpiresAt, scheduledAt, expireAt, startedAt, completedAt, failedAt *string
	if j.UniqueKey != nil {
		uniqueKey = j.UniqueKey
	}
	if j.BatchID != nil {
		batchID = j.BatchID
	}
	if j.WorkerID != nil {
		workerID = j.WorkerID
	}
	if j.Hostname != nil {
		hostname = j.Hostname
	}
	if j.LeaseExpiresAt != nil {
		s := j.LeaseExpiresAt.UTC().Format(time.RFC3339Nano)
		leaseExpiresAt = &s
	}
	if j.ScheduledAt != nil {
		s := j.ScheduledAt.UTC().Format(time.RFC3339Nano)
		scheduledAt = &s
	}
	if j.ExpireAt != nil {
		s := j.ExpireAt.UTC().Format(time.RFC3339Nano)
		expireAt = &s
	}
	if j.StartedAt != nil {
		s := j.StartedAt.UTC().Format(time.RFC3339Nano)
		startedAt = &s
	}
	if j.CompletedAt != nil {
		s := j.CompletedAt.UTC().Format(time.RFC3339Nano)
		completedAt = &s
	}
	if j.FailedAt != nil {
		s := j.FailedAt.UTC().Format(time.RFC3339Nano)
		failedAt = &s
	}
	createdAt := j.CreatedAt.UTC().Format(time.RFC3339Nano)

	_, err := db.Exec(`INSERT OR REPLACE INTO jobs (
		id, queue, state, payload, priority, attempt, max_retries,
		retry_backoff, retry_base_delay_ms, retry_max_delay_ms,
		unique_key, batch_id, worker_id, hostname, tags, progress, checkpoint, result,
		lease_expires_at, scheduled_at, expire_at, created_at, started_at, completed_at, failed_at
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		j.ID, j.Queue, j.State, string(j.Payload), j.Priority, j.Attempt, j.MaxRetries,
		j.RetryBackoff, j.RetryBaseDelay, j.RetryMaxDelay,
		uniqueKey, batchID, workerID, hostname, string(j.Tags), string(j.Progress), string(j.Checkpoint), string(j.Result),
		leaseExpiresAt, scheduledAt, expireAt, createdAt, startedAt, completedAt, failedAt,
	)
	if err != nil {
		return fmt.Errorf("upsert job %s: %w", j.ID, err)
	}
	return nil
}

func sqliteInsertJobErrorDoc(db sqlExecer, e store.JobError) error {
	var backtrace *string
	if e.Backtrace != nil {
		backtrace = e.Backtrace
	}
	createdAt := e.CreatedAt.UTC().Format(time.RFC3339Nano)
	_, err := db.Exec(
		"INSERT INTO job_errors (job_id, attempt, error, backtrace, created_at) VALUES (?, ?, ?, ?, ?)",
		e.JobID, e.Attempt, e.Error, backtrace, createdAt,
	)
	if err != nil {
		return fmt.Errorf("insert job_error for job %s: %w", e.JobID, err)
	}
	return nil
}

func sqliteUpsertBatchDoc(db sqlExecer, b store.Batch) error {
	var callbackQueue, callbackPayload *string
	if b.CallbackQueue != nil {
		callbackQueue = b.CallbackQueue
	}
	if len(b.CallbackPayload) > 0 {
		s := string(b.CallbackPayload)
		callbackPayload = &s
	}
	createdAt := b.CreatedAt.UTC().Format(time.RFC3339Nano)
	_, err := db.Exec(
		`INSERT OR REPLACE INTO batches (id, total, pending, succeeded, failed, callback_queue, callback_payload, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		b.ID, b.Total, b.Pending, b.Succeeded, b.Failed, callbackQueue, callbackPayload, createdAt,
	)
	if err != nil {
		return fmt.Errorf("upsert batch %s: %w", b.ID, err)
	}
	return nil
}

func sqliteUpsertWorkerDoc(db sqlExecer, w store.Worker) error {
	var hostname *string
	if w.Hostname != nil {
		hostname = w.Hostname
	}
	lastHeartbeat := w.LastHeartbeat.UTC().Format(time.RFC3339Nano)
	startedAt := w.StartedAt.UTC().Format(time.RFC3339Nano)
	_, err := db.Exec(
		`INSERT OR REPLACE INTO workers (id, hostname, queues, last_heartbeat, started_at)
		 VALUES (?, ?, ?, ?, ?)`,
		w.ID, hostname, string(w.Queues), lastHeartbeat, startedAt,
	)
	if err != nil {
		return fmt.Errorf("upsert worker %s: %w", w.ID, err)
	}
	return nil
}

func sqliteUpsertScheduleDoc(db sqlExecer, s store.Schedule) error {
	var uniqueKey, lastRun, nextRun *string
	if s.UniqueKey != nil {
		uniqueKey = s.UniqueKey
	}
	if s.LastRun != nil {
		x := s.LastRun.UTC().Format(time.RFC3339Nano)
		lastRun = &x
	}
	if s.NextRun != nil {
		x := s.NextRun.UTC().Format(time.RFC3339Nano)
		nextRun = &x
	}
	createdAt := s.CreatedAt.UTC().Format(time.RFC3339Nano)
	_, err := db.Exec(
		`INSERT OR REPLACE INTO schedules
		 (id, name, queue, cron, timezone, payload, unique_key, max_retries, last_run, next_run, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		s.ID, s.Name, s.Queue, s.Cron, s.Timezone, string(s.Payload), uniqueKey, s.MaxRetries, lastRun, nextRun, createdAt,
	)
	if err != nil {
		return fmt.Errorf("upsert schedule %s: %w", s.ID, err)
	}
	return nil
}

func parseUniqueKey(k []byte) (queue, unique string, ok bool) {
	rest := k[len(kv.PrefixUnique):]
	i := bytes.IndexByte(rest, 0)
	if i <= 0 || i+1 >= len(rest) {
		return "", "", false
	}
	return string(rest[:i]), string(rest[i+1:]), true
}

func parseRateLimitKey(k []byte) (queue string, fetchedNs uint64, ok bool) {
	rest := k[len(kv.PrefixRateLimit):]
	i := bytes.IndexByte(rest, 0)
	if i <= 0 || i+1+8 > len(rest) {
		return "", 0, false
	}
	queue = string(rest[:i])
	fetchedNs = kv.GetUint64BE(rest[i+1 : i+1+8])
	return queue, fetchedNs, true
}

func parseJobErrorKey(k []byte) (jobID string, attempt uint32, ok bool) {
	rest := k[len(kv.PrefixJobError):]
	i := bytes.IndexByte(rest, 0)
	if i <= 0 || i+1+4 > len(rest) {
		return "", 0, false
	}
	jobID = string(rest[:i])
	attempt = kv.GetUint32BE(rest[i+1 : i+1+4])
	return jobID, attempt, true
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
