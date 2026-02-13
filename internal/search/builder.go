package search

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Filter contains all available search filter fields.
type Filter struct {
	Queue           string            `json:"queue,omitempty"`
	State           []string          `json:"state,omitempty"`
	Priority        string            `json:"priority,omitempty"`
	Tags            map[string]string `json:"tags,omitempty"`
	PayloadContains string            `json:"payload_contains,omitempty"`
	PayloadJQ       string            `json:"payload_jq,omitempty"`
	CreatedAfter    *time.Time        `json:"created_after,omitempty"`
	CreatedBefore   *time.Time        `json:"created_before,omitempty"`
	ScheduledAfter  *time.Time        `json:"scheduled_after,omitempty"`
	ScheduledBefore *time.Time        `json:"scheduled_before,omitempty"`
	StartedAfter    *time.Time        `json:"started_after,omitempty"`
	StartedBefore   *time.Time        `json:"started_before,omitempty"`
	CompletedAfter  *time.Time        `json:"completed_after,omitempty"`
	CompletedBefore *time.Time        `json:"completed_before,omitempty"`
	ExpireBefore    *time.Time        `json:"expire_before,omitempty"`
	ExpireAfter     *time.Time        `json:"expire_after,omitempty"`
	AttemptMin      *int              `json:"attempt_min,omitempty"`
	AttemptMax      *int              `json:"attempt_max,omitempty"`
	UniqueKey       string            `json:"unique_key,omitempty"`
	BatchID         string            `json:"batch_id,omitempty"`
	WorkerID        string            `json:"worker_id,omitempty"`
	ParentID        string            `json:"parent_id,omitempty"`
	ChainID         string            `json:"chain_id,omitempty"`
	HasErrors       *bool             `json:"has_errors,omitempty"`
	ErrorContains   string            `json:"error_contains,omitempty"`
	JobIDPrefix     string            `json:"job_id_prefix,omitempty"`
	Sort            string            `json:"sort,omitempty"`
	Order           string            `json:"order,omitempty"`
	Cursor          string            `json:"cursor,omitempty"`
	Limit           int               `json:"limit,omitempty"`
}

// Result contains the search results.
type Result struct {
	Jobs    []map[string]interface{} `json:"jobs"`
	Total   int                      `json:"total"`
	Cursor  string                   `json:"cursor,omitempty"`
	HasMore bool                     `json:"has_more"`
}

// BuildQuery constructs a SELECT query from the search filter.
func BuildQuery(f Filter) (query string, countQuery string, args []interface{}, countArgs []interface{}, err error) {
	var conditions []string
	var queryArgs []interface{}

	if f.Queue != "" {
		conditions = append(conditions, "j.queue = ?")
		queryArgs = append(queryArgs, f.Queue)
	}

	if len(f.State) > 0 {
		placeholders := make([]string, len(f.State))
		for i, s := range f.State {
			placeholders[i] = "?"
			queryArgs = append(queryArgs, s)
		}
		conditions = append(conditions, fmt.Sprintf("j.state IN (%s)", strings.Join(placeholders, ", ")))
	}

	if f.Priority != "" {
		conditions = append(conditions, "j.priority = ?")
		queryArgs = append(queryArgs, priorityFromString(f.Priority))
	}

	if len(f.Tags) > 0 {
		for key, val := range f.Tags {
			conditions = append(conditions, fmt.Sprintf("json_extract(j.tags, '$.%s') = ?", key))
			queryArgs = append(queryArgs, val)
		}
	}

	if f.PayloadContains != "" {
		conditions = append(conditions, "j.payload LIKE '%' || ? || '%'")
		queryArgs = append(queryArgs, f.PayloadContains)
	}
	if strings.TrimSpace(f.PayloadJQ) != "" {
		clause, args, err := translatePayloadJQ(strings.TrimSpace(f.PayloadJQ))
		if err != nil {
			return "", "", nil, nil, err
		}
		conditions = append(conditions, clause)
		queryArgs = append(queryArgs, args...)
	}

	addTimeFilter(&conditions, &queryArgs, "j.created_at", f.CreatedAfter, f.CreatedBefore)
	addTimeFilter(&conditions, &queryArgs, "j.scheduled_at", f.ScheduledAfter, f.ScheduledBefore)
	addTimeFilter(&conditions, &queryArgs, "j.started_at", f.StartedAfter, f.StartedBefore)
	addTimeFilter(&conditions, &queryArgs, "j.completed_at", f.CompletedAfter, f.CompletedBefore)
	addTimeFilter(&conditions, &queryArgs, "j.expire_at", f.ExpireAfter, f.ExpireBefore)

	if f.AttemptMin != nil {
		conditions = append(conditions, "j.attempt >= ?")
		queryArgs = append(queryArgs, *f.AttemptMin)
	}
	if f.AttemptMax != nil {
		conditions = append(conditions, "j.attempt <= ?")
		queryArgs = append(queryArgs, *f.AttemptMax)
	}

	if f.UniqueKey != "" {
		conditions = append(conditions, "j.unique_key = ?")
		queryArgs = append(queryArgs, f.UniqueKey)
	}

	if f.BatchID != "" {
		conditions = append(conditions, "j.batch_id = ?")
		queryArgs = append(queryArgs, f.BatchID)
	}

	if f.WorkerID != "" {
		conditions = append(conditions, "j.worker_id = ?")
		queryArgs = append(queryArgs, f.WorkerID)
	}
	if f.ParentID != "" {
		conditions = append(conditions, "j.parent_id = ?")
		queryArgs = append(queryArgs, f.ParentID)
	}
	if f.ChainID != "" {
		conditions = append(conditions, "j.chain_id = ?")
		queryArgs = append(queryArgs, f.ChainID)
	}

	if f.HasErrors != nil && *f.HasErrors {
		conditions = append(conditions, "j.id IN (SELECT DISTINCT job_id FROM job_errors)")
	}

	if f.ErrorContains != "" {
		conditions = append(conditions, "j.id IN (SELECT job_id FROM job_errors WHERE error LIKE '%' || ? || '%')")
		queryArgs = append(queryArgs, f.ErrorContains)
	}

	if f.JobIDPrefix != "" {
		conditions = append(conditions, "j.id LIKE ? || '%'")
		queryArgs = append(queryArgs, f.JobIDPrefix)
	}

	where := ""
	if len(conditions) > 0 {
		where = "WHERE " + strings.Join(conditions, " AND ")
	}

	// Sort
	sortCol := "j.created_at"
	switch f.Sort {
	case "priority":
		sortCol = "j.priority"
	case "started_at":
		sortCol = "j.started_at"
	case "completed_at":
		sortCol = "j.completed_at"
	case "attempt":
		sortCol = "j.attempt"
	}

	order := "DESC"
	if f.Order == "asc" {
		order = "ASC"
	}

	// Pagination
	limit := 50
	if f.Limit > 0 && f.Limit <= 1000 {
		limit = f.Limit
	}

	offset := 0
	if f.Cursor != "" {
		offset = DecodeCursor(f.Cursor)
	}

	// Build count query (same args)
	countQuery = fmt.Sprintf("SELECT COUNT(*) FROM jobs j %s", where)
	countArgs = make([]interface{}, len(queryArgs))
	copy(countArgs, queryArgs)

	// Build main query
	query = fmt.Sprintf(`
		SELECT j.id, j.queue, j.state, j.payload, j.priority, j.attempt, j.max_retries,
			j.unique_key, j.batch_id, j.worker_id, j.tags, j.parent_id, j.chain_id, j.chain_step,
			j.created_at, j.started_at, j.completed_at, j.failed_at
		FROM jobs j
		%s
		ORDER BY %s %s
		LIMIT ? OFFSET ?
	`, where, sortCol, order)

	queryArgs = append(queryArgs, limit, offset)
	args = queryArgs

	return query, countQuery, args, countArgs, nil
}

// EncodeCursor encodes an offset as a base64 cursor.
func EncodeCursor(offset int) string {
	data, _ := json.Marshal(map[string]int{"offset": offset})
	return base64.StdEncoding.EncodeToString(data)
}

// DecodeCursor decodes a base64 cursor to an offset.
func DecodeCursor(cursor string) int {
	data, err := base64.StdEncoding.DecodeString(cursor)
	if err != nil {
		return 0
	}
	var m map[string]int
	if err := json.Unmarshal(data, &m); err != nil {
		return 0
	}
	return m["offset"]
}

func addTimeFilter(conditions *[]string, args *[]interface{}, col string, after, before *time.Time) {
	if after != nil {
		*conditions = append(*conditions, col+" > ?")
		*args = append(*args, after.UTC().Format("2006-01-02T15:04:05.000"))
	}
	if before != nil {
		*conditions = append(*conditions, col+" < ?")
		*args = append(*args, before.UTC().Format("2006-01-02T15:04:05.000"))
	}
}

func priorityFromString(s string) int {
	switch s {
	case "critical":
		return 0
	case "high":
		return 1
	default:
		return 2
	}
}
