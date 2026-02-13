package store

import (
	"fmt"
	"strings"
	"time"
)

// UsageReport captures optional token/cost metadata reported by workers.
type UsageReport struct {
	InputTokens         int64   `json:"input_tokens,omitempty"`
	OutputTokens        int64   `json:"output_tokens,omitempty"`
	CacheCreationTokens int64   `json:"cache_creation_tokens,omitempty"`
	CacheReadTokens     int64   `json:"cache_read_tokens,omitempty"`
	Model               string  `json:"model,omitempty"`
	Provider            string  `json:"provider,omitempty"`
	CostUSD             float64 `json:"cost_usd,omitempty"`
}

func (u *UsageReport) IsZero() bool {
	return u == nil ||
		(u.InputTokens == 0 &&
			u.OutputTokens == 0 &&
			u.CacheCreationTokens == 0 &&
			u.CacheReadTokens == 0 &&
			u.CostUSD == 0 &&
			u.Model == "" &&
			u.Provider == "")
}

func normalizeUsage(u *UsageReport) *UsageReport {
	if u == nil {
		return nil
	}
	out := *u
	if out.InputTokens < 0 {
		out.InputTokens = 0
	}
	if out.OutputTokens < 0 {
		out.OutputTokens = 0
	}
	if out.CacheCreationTokens < 0 {
		out.CacheCreationTokens = 0
	}
	if out.CacheReadTokens < 0 {
		out.CacheReadTokens = 0
	}
	if out.CostUSD < 0 {
		out.CostUSD = 0
	}
	out.Model = strings.TrimSpace(out.Model)
	out.Provider = strings.TrimSpace(out.Provider)
	if out.IsZero() {
		return nil
	}
	return &out
}

type UsageSummaryRequest struct {
	Period  string
	GroupBy string
	Now     time.Time
}

type UsageSummaryTotals struct {
	InputTokens         int64   `json:"input_tokens"`
	OutputTokens        int64   `json:"output_tokens"`
	CacheCreationTokens int64   `json:"cache_creation_tokens"`
	CacheReadTokens     int64   `json:"cache_read_tokens"`
	CostUSD             float64 `json:"cost_usd"`
	Count               int64   `json:"count"`
}

type UsageSummaryGroup struct {
	Key string `json:"key"`
	UsageSummaryTotals
}

type UsageSummaryResponse struct {
	Period string              `json:"period"`
	From   time.Time           `json:"from"`
	To     time.Time           `json:"to"`
	Totals UsageSummaryTotals  `json:"totals"`
	Groups []UsageSummaryGroup `json:"groups,omitempty"`
}

func (s *Store) UsageSummary(req UsageSummaryRequest) (*UsageSummaryResponse, error) {
	if s.sqliteR == nil {
		return nil, fmt.Errorf("sqlite read database unavailable")
	}
	periodStr := strings.TrimSpace(req.Period)
	if periodStr == "" {
		periodStr = "24h"
	}
	d, err := time.ParseDuration(periodStr)
	if err != nil || d <= 0 {
		return nil, fmt.Errorf("invalid period: %q", periodStr)
	}
	to := req.Now
	if to.IsZero() {
		to = time.Now()
	}
	from := to.Add(-d)
	fromStr := from.UTC().Format(time.RFC3339Nano)
	toStr := to.UTC().Format(time.RFC3339Nano)

	resp := &UsageSummaryResponse{
		Period: periodStr,
		From:   from.UTC(),
		To:     to.UTC(),
	}
	if err := s.sqliteR.QueryRow(`
		SELECT
			COALESCE(SUM(input_tokens), 0),
			COALESCE(SUM(output_tokens), 0),
			COALESCE(SUM(cache_creation_tokens), 0),
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(cost_usd), 0),
			COUNT(*)
		FROM job_usage
		WHERE created_at >= ? AND created_at <= ?`,
		fromStr, toStr,
	).Scan(
		&resp.Totals.InputTokens,
		&resp.Totals.OutputTokens,
		&resp.Totals.CacheCreationTokens,
		&resp.Totals.CacheReadTokens,
		&resp.Totals.CostUSD,
		&resp.Totals.Count,
	); err != nil {
		return nil, err
	}

	groupBy := strings.TrimSpace(req.GroupBy)
	var col string
	switch groupBy {
	case "", "none":
		return resp, nil
	case "queue":
		col = "queue"
	case "model":
		col = "model"
	case "provider":
		col = "provider"
	default:
		return nil, fmt.Errorf("unsupported group_by: %q", groupBy)
	}

	rows, err := s.sqliteR.Query(fmt.Sprintf(`
		SELECT
			COALESCE(%s, ''),
			COALESCE(SUM(input_tokens), 0),
			COALESCE(SUM(output_tokens), 0),
			COALESCE(SUM(cache_creation_tokens), 0),
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(cost_usd), 0),
			COUNT(*)
		FROM job_usage
		WHERE created_at >= ? AND created_at <= ?
		GROUP BY %s
		ORDER BY SUM(cost_usd) DESC`, col, col),
		fromStr, toStr,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var g UsageSummaryGroup
		if err := rows.Scan(
			&g.Key,
			&g.InputTokens,
			&g.OutputTokens,
			&g.CacheCreationTokens,
			&g.CacheReadTokens,
			&g.CostUSD,
			&g.Count,
		); err != nil {
			return nil, err
		}
		resp.Groups = append(resp.Groups, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return resp, nil
}
