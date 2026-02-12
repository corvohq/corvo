package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/user/jobbie/internal/search"
)

// BulkRequest describes a bulk operation.
type BulkRequest struct {
	JobIDs     []string      `json:"job_ids,omitempty"`
	Filter     *search.Filter `json:"filter,omitempty"`
	Action     string        `json:"action"` // retry, delete, cancel, move, requeue, change_priority
	MoveToQueue string       `json:"move_to_queue,omitempty"`
	Priority    string       `json:"priority,omitempty"`
}

// BulkResult is the response from a bulk operation.
type BulkResult struct {
	Affected   int   `json:"affected"`
	Errors     int   `json:"errors"`
	DurationMs int64 `json:"duration_ms"`
}

// BulkAction applies an action to multiple jobs.
func (s *Store) BulkAction(req BulkRequest) (*BulkResult, error) {
	start := time.Now()

	// Resolve job IDs from filter if needed
	jobIDs := req.JobIDs
	if len(jobIDs) == 0 && req.Filter != nil {
		ids, err := s.resolveFilterToIDs(*req.Filter)
		if err != nil {
			return nil, fmt.Errorf("resolve filter: %w", err)
		}
		jobIDs = ids
	}

	if len(jobIDs) == 0 {
		return &BulkResult{DurationMs: time.Since(start).Milliseconds()}, nil
	}

	var affected int64
	var bulkErr error

	switch req.Action {
	case "retry":
		affected, bulkErr = s.bulkRetry(jobIDs)
	case "delete":
		affected, bulkErr = s.bulkDelete(jobIDs)
	case "cancel":
		affected, bulkErr = s.bulkCancel(jobIDs)
	case "move":
		if req.MoveToQueue == "" {
			return nil, fmt.Errorf("move_to_queue is required for move action")
		}
		affected, bulkErr = s.bulkMove(jobIDs, req.MoveToQueue)
	case "requeue":
		affected, bulkErr = s.bulkRequeue(jobIDs)
	case "change_priority":
		if req.Priority == "" {
			return nil, fmt.Errorf("priority is required for change_priority action")
		}
		affected, bulkErr = s.bulkChangePriority(jobIDs, PriorityFromString(req.Priority))
	default:
		return nil, fmt.Errorf("unknown bulk action: %q", req.Action)
	}

	if bulkErr != nil {
		return nil, bulkErr
	}

	return &BulkResult{
		Affected:   int(affected),
		DurationMs: time.Since(start).Milliseconds(),
	}, nil
}

func (s *Store) resolveFilterToIDs(filter search.Filter) ([]string, error) {
	filter.Limit = 0 // no limit for bulk
	query, _, args, _, err := search.BuildQuery(filter)
	if err != nil {
		return nil, err
	}

	// Replace the SELECT ... with SELECT j.id
	// The query starts with SELECT ...fields... FROM jobs j
	idx := strings.Index(query, "FROM jobs j")
	if idx == -1 {
		return nil, fmt.Errorf("unexpected query format")
	}
	idQuery := "SELECT j.id " + query[idx:]

	rows, err := s.db.Read.Query(idQuery, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) bulkRetry(jobIDs []string) (int64, error) {
	return s.bulkExec(
		`UPDATE jobs SET state = 'pending', attempt = 0, failed_at = NULL, completed_at = NULL,
			worker_id = NULL, hostname = NULL, lease_expires_at = NULL, scheduled_at = NULL
		WHERE id IN (%s) AND state IN ('dead', 'cancelled', 'completed')`,
		jobIDs,
	)
}

func (s *Store) bulkDelete(jobIDs []string) (int64, error) {
	return s.bulkExec(`DELETE FROM jobs WHERE id IN (%s)`, jobIDs)
}

func (s *Store) bulkCancel(jobIDs []string) (int64, error) {
	return s.bulkExec(
		`UPDATE jobs SET state = 'cancelled' WHERE id IN (%s) AND state IN ('pending', 'active', 'scheduled', 'retrying')`,
		jobIDs,
	)
}

func (s *Store) bulkMove(jobIDs []string, targetQueue string) (int64, error) {
	// Ensure target queue exists
	s.writer.Execute("INSERT OR IGNORE INTO queues (name) VALUES (?)", targetQueue)

	placeholders := make([]string, len(jobIDs))
	args := make([]interface{}, 0, len(jobIDs)+1)
	args = append(args, targetQueue)
	for i, id := range jobIDs {
		placeholders[i] = "?"
		args = append(args, id)
	}

	query := fmt.Sprintf(
		`UPDATE jobs SET queue = ? WHERE id IN (%s)`,
		strings.Join(placeholders, ", "),
	)
	result, err := s.writer.Execute(query, args...)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) bulkRequeue(jobIDs []string) (int64, error) {
	return s.bulkExec(
		`UPDATE jobs SET state = 'pending', failed_at = NULL, worker_id = NULL, hostname = NULL,
			lease_expires_at = NULL, scheduled_at = NULL
		WHERE id IN (%s) AND state = 'dead'`,
		jobIDs,
	)
}

func (s *Store) bulkChangePriority(jobIDs []string, priority int) (int64, error) {
	placeholders := make([]string, len(jobIDs))
	args := make([]interface{}, 0, len(jobIDs)+1)
	args = append(args, priority)
	for i, id := range jobIDs {
		placeholders[i] = "?"
		args = append(args, id)
	}

	query := fmt.Sprintf(
		`UPDATE jobs SET priority = ? WHERE id IN (%s) AND state IN ('pending', 'scheduled')`,
		strings.Join(placeholders, ", "),
	)
	result, err := s.writer.Execute(query, args...)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) bulkExec(queryTemplate string, jobIDs []string) (int64, error) {
	placeholders := make([]string, len(jobIDs))
	args := make([]interface{}, len(jobIDs))
	for i, id := range jobIDs {
		placeholders[i] = "?"
		args[i] = id
	}

	query := fmt.Sprintf(queryTemplate, strings.Join(placeholders, ", "))

	var result sql.Result
	var err error
	result, err = s.writer.Execute(query, args...)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
