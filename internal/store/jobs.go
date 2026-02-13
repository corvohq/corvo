package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// GetJob returns a job with its error history from local SQLite.
func (s *Store) GetJob(id string) (*Job, error) {
	var j Job
	var payload, tags, progress, checkpoint, result sql.NullString
	var agentIterTimeout, holdReason sql.NullString
	var uniqueKey, batchID, workerID, hostname sql.NullString
	var agentMaxIterations sql.NullInt64
	var agentIteration sql.NullInt64
	var agentMaxCostUSD sql.NullFloat64
	var agentTotalCostUSD sql.NullFloat64
	var leaseExpiresAt, scheduledAt, expireAt, startedAt, completedAt, failedAt sql.NullString
	var createdAt string

	err := s.sqliteR.QueryRow(`
		SELECT id, queue, state, payload, priority, attempt, max_retries,
			retry_backoff, retry_base_delay_ms, retry_max_delay_ms,
			unique_key, batch_id, worker_id, hostname,
			tags, progress, checkpoint, result,
			agent_max_iterations, agent_max_cost_usd, agent_iteration_timeout, agent_iteration, agent_total_cost_usd,
			hold_reason,
			lease_expires_at, scheduled_at, expire_at,
			created_at, started_at, completed_at, failed_at
		FROM jobs WHERE id = ?
	`, id).Scan(
		&j.ID, &j.Queue, &j.State, &payload, &j.Priority, &j.Attempt, &j.MaxRetries,
		&j.RetryBackoff, &j.RetryBaseDelay, &j.RetryMaxDelay,
		&uniqueKey, &batchID, &workerID, &hostname,
		&tags, &progress, &checkpoint, &result,
		&agentMaxIterations, &agentMaxCostUSD, &agentIterTimeout, &agentIteration, &agentTotalCostUSD,
		&holdReason,
		&leaseExpiresAt, &scheduledAt, &expireAt,
		&createdAt, &startedAt, &completedAt, &failedAt,
	)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("job %q not found", id)
	}
	if err != nil {
		return nil, fmt.Errorf("get job: %w", err)
	}

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
	if agentIteration.Valid {
		j.Agent = &AgentState{
			Iteration: int(agentIteration.Int64),
		}
		if agentMaxIterations.Valid {
			j.Agent.MaxIterations = int(agentMaxIterations.Int64)
		}
		if agentMaxCostUSD.Valid {
			j.Agent.MaxCostUSD = agentMaxCostUSD.Float64
		}
		if agentIterTimeout.Valid {
			j.Agent.IterationTimeout = agentIterTimeout.String
		}
		if agentTotalCostUSD.Valid {
			j.Agent.TotalCostUSD = agentTotalCostUSD.Float64
		}
	}
	if holdReason.Valid {
		j.HoldReason = &holdReason.String
	}
	j.CreatedAt = parseTime(createdAt)
	j.LeaseExpiresAt = parseNullableTime(leaseExpiresAt)
	j.ScheduledAt = parseNullableTime(scheduledAt)
	j.ExpireAt = parseNullableTime(expireAt)
	j.StartedAt = parseNullableTime(startedAt)
	j.CompletedAt = parseNullableTime(completedAt)
	j.FailedAt = parseNullableTime(failedAt)

	// Load errors
	rows, err := s.sqliteR.Query(
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

func (s *Store) ReplayFromIteration(id string, from int) (*EnqueueResult, error) {
	if from <= 0 {
		return nil, fmt.Errorf("from iteration must be > 0")
	}
	job, err := s.GetJob(id)
	if err != nil {
		return nil, err
	}
	if job.Agent == nil {
		return nil, fmt.Errorf("job %q is not an agent job", id)
	}

	var checkpoint sql.NullString
	foundIteration := false
	// SQLite mirror writes may be async; briefly wait for the iteration row.
	deadline := time.Now().Add(2 * time.Second)
	for {
		err = s.sqliteR.QueryRow(
			"SELECT checkpoint FROM job_iterations WHERE job_id = ? AND iteration = ? LIMIT 1",
			id, from,
		).Scan(&checkpoint)
		if err == nil {
			foundIteration = true
			break
		}
		if err != sql.ErrNoRows {
			return nil, fmt.Errorf("lookup iteration %d for %q: %w", from, id, err)
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	req := EnqueueRequest{
		Queue:      job.Queue,
		Payload:    job.Payload,
		Priority:   PriorityToString(job.Priority),
		Tags:       job.Tags,
		Checkpoint: nil,
		Agent: &AgentConfig{
			MaxIterations:    job.Agent.MaxIterations,
			MaxCostUSD:       job.Agent.MaxCostUSD,
			IterationTimeout: job.Agent.IterationTimeout,
		},
	}
	if checkpoint.Valid && checkpoint.String != "" {
		req.Checkpoint = json.RawMessage(checkpoint.String)
	} else if !foundIteration {
		// Fallback when async mirror lag/drops prevent iteration row lookup.
		if len(job.Checkpoint) == 0 {
			return nil, fmt.Errorf("iteration %d not found for job %q", from, id)
		}
		req.Checkpoint = append(json.RawMessage(nil), job.Checkpoint...)
	}
	return s.Enqueue(req)
}

// RetryJob resets a dead/cancelled/completed job back to pending via Raft.
func (s *Store) RetryJob(id string) error {
	now := time.Now()
	op := RetryJobOp{
		JobID: id,
		NowNs: uint64(now.UnixNano()),
	}
	res := s.applyOp(OpRetryJob, op)
	return res.Err
}

// CancelJob cancels a job via Raft.
func (s *Store) CancelJob(id string) (string, error) {
	now := time.Now()
	op := CancelJobOp{
		JobID: id,
		NowNs: uint64(now.UnixNano()),
	}
	res := s.applyOp(OpCancelJob, op)
	if res.Err != nil {
		return "", res.Err
	}
	if status, ok := res.Data.(string); ok {
		return status, nil
	}
	return StateCancelled, nil
}

// MoveJob moves a job to a different queue via Raft.
func (s *Store) MoveJob(id, targetQueue string) error {
	now := time.Now()
	op := MoveJobOp{
		JobID:       id,
		TargetQueue: targetQueue,
		NowNs:       uint64(now.UnixNano()),
	}
	res := s.applyOp(OpMoveJob, op)
	return res.Err
}

// DeleteJob permanently removes a job via Raft.
func (s *Store) DeleteJob(id string) error {
	op := DeleteJobOp{
		JobID: id,
	}
	res := s.applyOp(OpDeleteJob, op)
	return res.Err
}

// HoldJob moves a job into held state for human review.
func (s *Store) HoldJob(id string) error {
	job, err := s.GetJob(id)
	if err != nil {
		return err
	}
	result, err := s.BulkAction(BulkRequest{
		JobIDs: []string{id},
		Action: "hold",
	})
	if err != nil {
		return err
	}
	if result.Affected == 0 {
		return fmt.Errorf("job %q cannot be held from state %q", id, job.State)
	}
	return nil
}

// ApproveJob releases a held job back to pending.
func (s *Store) ApproveJob(id string) error {
	job, err := s.GetJob(id)
	if err != nil {
		return err
	}
	result, err := s.BulkAction(BulkRequest{
		JobIDs: []string{id},
		Action: "approve",
	})
	if err != nil {
		return err
	}
	if result.Affected == 0 {
		return fmt.Errorf("job %q cannot be approved from state %q", id, job.State)
	}
	return nil
}

// RejectJob rejects a held job and moves it to dead.
func (s *Store) RejectJob(id string) error {
	job, err := s.GetJob(id)
	if err != nil {
		return err
	}
	result, err := s.BulkAction(BulkRequest{
		JobIDs: []string{id},
		Action: "reject",
	})
	if err != nil {
		return err
	}
	if result.Affected == 0 {
		return fmt.Errorf("job %q cannot be rejected from state %q", id, job.State)
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
