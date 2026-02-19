package store

import (
	"fmt"
	"strings"
	"time"

	"github.com/corvohq/corvo/internal/search"
)

// BulkRequest describes a bulk operation.
type BulkRequest struct {
	JobIDs      []string       `json:"job_ids,omitempty"`
	Filter      *search.Filter `json:"filter,omitempty"`
	Action      string         `json:"action"` // retry, delete, cancel, move, requeue, change_priority, hold, approve, reject
	MoveToQueue string         `json:"move_to_queue,omitempty"`
	Priority    string         `json:"priority,omitempty"`
}

// BulkResult is the response from a bulk operation.
type BulkResult struct {
	Affected   int   `json:"affected"`
	Errors     int   `json:"errors"`
	DurationMs int64 `json:"duration_ms"`
}

// BulkAction applies an action to multiple jobs via Raft.
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

	// Validate action
	switch req.Action {
	case "retry", "delete", "cancel", "move", "requeue", "change_priority", "hold", "approve", "reject":
	default:
		return nil, fmt.Errorf("unknown bulk action: %q", req.Action)
	}

	if req.Action == "move" && req.MoveToQueue == "" {
		return nil, fmt.Errorf("move_to_queue is required for move action")
	}

	priority := 0
	if req.Action == "change_priority" {
		if req.Priority == "" {
			return nil, fmt.Errorf("priority is required for change_priority action")
		}
		priority = PriorityFromString(req.Priority)
	}

	op := BulkActionOp{
		JobIDs:      jobIDs,
		Action:      req.Action,
		MoveToQueue: req.MoveToQueue,
		Priority:    priority,
		NowNs:       uint64(start.UnixNano()),
	}

	result, err := applyOpResult[BulkResult](s, OpBulkAction, op)
	if err != nil {
		return nil, err
	}
	if result == nil {
		result = &BulkResult{}
	}
	result.DurationMs = time.Since(start).Milliseconds()
	return result, nil
}

func (s *Store) resolveFilterToIDs(filter search.Filter) ([]string, error) {
	filter.Limit = 0 // no limit for bulk
	query, _, args, _, err := search.BuildQuery(filter)
	if err != nil {
		return nil, err
	}

	// Replace the SELECT ... with SELECT j.id
	idx := strings.Index(query, "FROM jobs j")
	if idx == -1 {
		return nil, fmt.Errorf("unexpected query format")
	}
	idQuery := "SELECT j.id " + query[idx:]

	rows, err := s.sqliteR.Query(idQuery, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

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
