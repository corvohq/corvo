package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/user/jobbie/internal/search"
)

// SearchResult is the search response returned to callers.
type SearchResult struct {
	Jobs       []JobSummary `json:"jobs"`
	Total      int          `json:"total"`
	Cursor     string       `json:"cursor,omitempty"`
	HasMore    bool         `json:"has_more"`
	DurationMs int64        `json:"duration_ms"`
}

// JobSummary is a lightweight job representation for search results.
type JobSummary struct {
	ID          string          `json:"id"`
	Queue       string          `json:"queue"`
	State       string          `json:"state"`
	Payload     json.RawMessage `json:"payload"`
	Priority    int             `json:"priority"`
	Attempt     int             `json:"attempt"`
	MaxRetries  int             `json:"max_retries"`
	UniqueKey   *string         `json:"unique_key,omitempty"`
	BatchID     *string         `json:"batch_id,omitempty"`
	WorkerID    *string         `json:"worker_id,omitempty"`
	Tags        json.RawMessage `json:"tags,omitempty"`
	ParentID    *string         `json:"parent_id,omitempty"`
	ChainID     *string         `json:"chain_id,omitempty"`
	ChainStep   *int            `json:"chain_step,omitempty"`
	CreatedAt   *string         `json:"created_at,omitempty"`
	StartedAt   *string         `json:"started_at,omitempty"`
	CompletedAt *string         `json:"completed_at,omitempty"`
	FailedAt    *string         `json:"failed_at,omitempty"`
}

// SearchJobs executes a search query against local SQLite.
func (s *Store) SearchJobs(filter search.Filter) (*SearchResult, error) {
	start := time.Now()

	query, countQuery, args, countArgs, err := search.BuildQuery(filter)
	if err != nil {
		return nil, fmt.Errorf("build search query: %w", err)
	}

	// Get total count
	var total int
	if err := s.sqliteR.QueryRow(countQuery, countArgs...).Scan(&total); err != nil {
		return nil, fmt.Errorf("count search results: %w", err)
	}

	// Execute search
	rows, err := s.sqliteR.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("search jobs: %w", err)
	}
	defer rows.Close()

	var jobs []JobSummary
	for rows.Next() {
		var j JobSummary
		var payload sql.NullString
		var uniqueKey, batchID, workerID, tags, parentID, chainID sql.NullString
		var chainStep sql.NullInt64
		var createdAt, startedAt, completedAt, failedAt sql.NullString
		err := rows.Scan(
			&j.ID, &j.Queue, &j.State, &payload, &j.Priority, &j.Attempt, &j.MaxRetries,
			&uniqueKey, &batchID, &workerID, &tags, &parentID, &chainID, &chainStep,
			&createdAt, &startedAt, &completedAt, &failedAt,
		)
		if err != nil {
			return nil, fmt.Errorf("scan job: %w", err)
		}
		if payload.Valid {
			j.Payload = json.RawMessage(payload.String)
		}
		if uniqueKey.Valid {
			j.UniqueKey = &uniqueKey.String
		}
		if batchID.Valid {
			j.BatchID = &batchID.String
		}
		if workerID.Valid {
			j.WorkerID = &workerID.String
		}
		if tags.Valid {
			j.Tags = json.RawMessage(tags.String)
		}
		if parentID.Valid {
			j.ParentID = &parentID.String
		}
		if chainID.Valid {
			j.ChainID = &chainID.String
		}
		if chainStep.Valid {
			s := int(chainStep.Int64)
			j.ChainStep = &s
		}
		if createdAt.Valid {
			j.CreatedAt = &createdAt.String
		}
		if startedAt.Valid {
			j.StartedAt = &startedAt.String
		}
		if completedAt.Valid {
			j.CompletedAt = &completedAt.String
		}
		if failedAt.Valid {
			j.FailedAt = &failedAt.String
		}
		jobs = append(jobs, j)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	offset := 0
	if filter.Cursor != "" {
		offset = search.DecodeCursor(filter.Cursor)
	}

	nextOffset := offset + len(jobs)
	hasMore := nextOffset < total
	var cursor string
	if hasMore {
		cursor = search.EncodeCursor(nextOffset)
	}

	return &SearchResult{
		Jobs:       jobs,
		Total:      total,
		Cursor:     cursor,
		HasMore:    hasMore,
		DurationMs: time.Since(start).Milliseconds(),
	}, nil
}
