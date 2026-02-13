package store

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

type JobScore struct {
	ID        int     `json:"id"`
	JobID     string  `json:"job_id"`
	Dimension string  `json:"dimension"`
	Value     float64 `json:"value"`
	Scorer    *string `json:"scorer,omitempty"`
	CreatedAt string  `json:"created_at"`
}

type AddScoreRequest struct {
	JobID     string  `json:"job_id"`
	Dimension string  `json:"dimension"`
	Value     float64 `json:"value"`
	Scorer    string  `json:"scorer,omitempty"`
}

type ScoreSummaryRequest struct {
	Queue  string
	Period string
}

type ScoreDimensionSummary struct {
	Mean  float64 `json:"mean"`
	P50   float64 `json:"p50"`
	P5    float64 `json:"p5"`
	Count int64   `json:"count"`
}

type ScoreSummaryResponse struct {
	Queue      string                           `json:"queue,omitempty"`
	Period     string                           `json:"period"`
	Dimensions map[string]ScoreDimensionSummary `json:"dimensions"`
}

type ScoreCompareRequest struct {
	Queue   string
	Period  string
	GroupBy string
}

type ScoreCompareGroup struct {
	Key        string                           `json:"key"`
	Dimensions map[string]ScoreDimensionSummary `json:"dimensions"`
}

type ScoreCompareResponse struct {
	Queue   string              `json:"queue,omitempty"`
	Period  string              `json:"period"`
	GroupBy string              `json:"group_by"`
	Groups  []ScoreCompareGroup `json:"groups"`
}

func (s *Store) AddScore(req AddScoreRequest) (*JobScore, error) {
	jobID := strings.TrimSpace(req.JobID)
	dim := strings.TrimSpace(req.Dimension)
	if jobID == "" {
		return nil, fmt.Errorf("job_id is required")
	}
	if dim == "" {
		return nil, fmt.Errorf("dimension is required")
	}
	if req.Value < 0 || req.Value > 1 {
		return nil, fmt.Errorf("value must be between 0 and 1")
	}
	var scorer any
	if strings.TrimSpace(req.Scorer) != "" {
		scorer = strings.TrimSpace(req.Scorer)
	}
	_, err := s.sqliteR.Exec(
		"INSERT INTO job_scores (job_id, dimension, value, scorer) VALUES (?, ?, ?, ?)",
		jobID, dim, req.Value, scorer,
	)
	if err != nil {
		return nil, err
	}
	var out JobScore
	var scorerNull *string
	err = s.sqliteR.QueryRow(`
		SELECT id, job_id, dimension, value, scorer, created_at
		FROM job_scores
		WHERE rowid = last_insert_rowid()
	`).Scan(&out.ID, &out.JobID, &out.Dimension, &out.Value, &scorerNull, &out.CreatedAt)
	if err != nil {
		return nil, err
	}
	out.Scorer = scorerNull
	return &out, nil
}

func (s *Store) ListJobScores(jobID string) ([]JobScore, error) {
	jobID = strings.TrimSpace(jobID)
	if jobID == "" {
		return nil, fmt.Errorf("job_id is required")
	}
	rows, err := s.sqliteR.Query(`
		SELECT id, job_id, dimension, value, scorer, created_at
		FROM job_scores
		WHERE job_id = ?
		ORDER BY created_at DESC, id DESC`, jobID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]JobScore, 0)
	for rows.Next() {
		var sRow JobScore
		if err := rows.Scan(&sRow.ID, &sRow.JobID, &sRow.Dimension, &sRow.Value, &sRow.Scorer, &sRow.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, sRow)
	}
	return out, rows.Err()
}

func (s *Store) ScoreSummary(req ScoreSummaryRequest) (*ScoreSummaryResponse, error) {
	period := strings.TrimSpace(req.Period)
	if period == "" {
		period = "24h"
	}
	d, err := time.ParseDuration(period)
	if err != nil || d <= 0 {
		return nil, fmt.Errorf("invalid period: %q", period)
	}
	from := time.Now().UTC().Add(-d).Format(time.RFC3339Nano)
	queue := strings.TrimSpace(req.Queue)
	rows, err := s.sqliteR.Query(`
		SELECT js.dimension, js.value
		FROM job_scores js
		JOIN jobs j ON j.id = js.job_id
		WHERE js.created_at >= ?
		  AND (? = '' OR j.queue = ?)
		ORDER BY js.dimension, js.value`,
		from, queue, queue,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	byDim := map[string][]float64{}
	for rows.Next() {
		var dim string
		var value float64
		if err := rows.Scan(&dim, &value); err != nil {
			return nil, err
		}
		byDim[dim] = append(byDim[dim], value)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	resp := &ScoreSummaryResponse{
		Queue:      queue,
		Period:     period,
		Dimensions: map[string]ScoreDimensionSummary{},
	}
	for dim, vals := range byDim {
		if len(vals) == 0 {
			continue
		}
		sum := 0.0
		for _, v := range vals {
			sum += v
		}
		resp.Dimensions[dim] = ScoreDimensionSummary{
			Mean:  sum / float64(len(vals)),
			P50:   percentile(vals, 50),
			P5:    percentile(vals, 5),
			Count: int64(len(vals)),
		}
	}
	return resp, nil
}

func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return sorted[0]
	}
	if p <= 0 {
		return sorted[0]
	}
	if p >= 100 {
		return sorted[len(sorted)-1]
	}
	idx := int((p / 100.0) * float64(len(sorted)-1))
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

var scoreCompareTagKeyPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func (s *Store) ScoreCompare(req ScoreCompareRequest) (*ScoreCompareResponse, error) {
	period := strings.TrimSpace(req.Period)
	if period == "" {
		period = "24h"
	}
	d, err := time.ParseDuration(period)
	if err != nil || d <= 0 {
		return nil, fmt.Errorf("invalid period: %q", period)
	}
	groupBy := strings.ToLower(strings.TrimSpace(req.GroupBy))
	if groupBy == "" {
		groupBy = "queue"
	}
	queue := strings.TrimSpace(req.Queue)
	from := time.Now().UTC().Add(-d).Format(time.RFC3339Nano)

	rows, err := s.sqliteR.Query(`
		SELECT js.dimension, js.value, j.queue, j.tags
		FROM job_scores js
		JOIN jobs j ON j.id = js.job_id
		WHERE js.created_at >= ?
		  AND (? = '' OR j.queue = ?)
		ORDER BY js.dimension, js.value`,
		from, queue, queue,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	valuesByGroupByDim := map[string]map[string][]float64{}
	for rows.Next() {
		var dim string
		var value float64
		var rowQueue string
		var tagsJSON *string
		if err := rows.Scan(&dim, &value, &rowQueue, &tagsJSON); err != nil {
			return nil, err
		}

		groupKey := "(unknown)"
		switch {
		case groupBy == "queue":
			if strings.TrimSpace(rowQueue) != "" {
				groupKey = strings.TrimSpace(rowQueue)
			}
		case strings.HasPrefix(groupBy, "tag:"):
			tagKey := strings.TrimSpace(strings.TrimPrefix(groupBy, "tag:"))
			if tagKey == "" || !scoreCompareTagKeyPattern.MatchString(tagKey) {
				return nil, fmt.Errorf("invalid group_by tag key: %q", tagKey)
			}
			groupKey = "(none)"
			if tagsJSON != nil && strings.TrimSpace(*tagsJSON) != "" {
				var tags map[string]any
				if err := json.Unmarshal([]byte(*tagsJSON), &tags); err == nil {
					if v, ok := tags[tagKey]; ok && v != nil {
						groupKey = fmt.Sprintf("%v", v)
					}
				}
			}
		default:
			return nil, fmt.Errorf("unsupported group_by: %q", groupBy)
		}

		if _, ok := valuesByGroupByDim[groupKey]; !ok {
			valuesByGroupByDim[groupKey] = map[string][]float64{}
		}
		valuesByGroupByDim[groupKey][dim] = append(valuesByGroupByDim[groupKey][dim], value)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	resp := &ScoreCompareResponse{
		Queue:   queue,
		Period:  period,
		GroupBy: groupBy,
		Groups:  make([]ScoreCompareGroup, 0, len(valuesByGroupByDim)),
	}
	for groupKey, dims := range valuesByGroupByDim {
		g := ScoreCompareGroup{
			Key:        groupKey,
			Dimensions: map[string]ScoreDimensionSummary{},
		}
		for dim, vals := range dims {
			if len(vals) == 0 {
				continue
			}
			sum := 0.0
			for _, v := range vals {
				sum += v
			}
			g.Dimensions[dim] = ScoreDimensionSummary{
				Mean:  sum / float64(len(vals)),
				P50:   percentile(vals, 50),
				P5:    percentile(vals, 5),
				Count: int64(len(vals)),
			}
		}
		resp.Groups = append(resp.Groups, g)
	}
	return resp, nil
}
