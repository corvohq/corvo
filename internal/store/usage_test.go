package store

import (
	"testing"
	"time"
)

func TestUsageSummaryTotalsAndGroupBy(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer func() { _ = db.Close() }()

	now := time.Date(2026, 2, 13, 12, 0, 0, 0, time.UTC)
	rows := []struct {
		jobID       string
		queue       string
		attempt     int
		phase       string
		in          int64
		out         int64
		cacheCreate int64
		cacheRead   int64
		model       string
		provider    string
		cost        float64
		createdAt   time.Time
	}{
		{"job-1", "q-a", 1, "ack", 100, 20, 0, 0, "gpt-4.1", "openai", 0.12, now.Add(-1 * time.Hour)},
		{"job-2", "q-a", 1, "heartbeat", 30, 5, 10, 2, "gpt-4.1", "openai", 0.03, now.Add(-30 * time.Minute)},
		{"job-3", "q-b", 2, "ack", 80, 10, 0, 0, "claude-3.5", "anthropic", 0.08, now.Add(-20 * time.Minute)},
	}
	for _, r := range rows {
		_, err := db.Write.Exec(`INSERT INTO job_usage (
			job_id, queue, attempt, phase, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
			model, provider, cost_usd, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			r.jobID, r.queue, r.attempt, r.phase, r.in, r.out, r.cacheCreate, r.cacheRead,
			r.model, r.provider, r.cost, r.createdAt.UTC().Format(time.RFC3339Nano),
		)
		if err != nil {
			t.Fatalf("insert usage row: %v", err)
		}
	}

	s := &Store{sqliteR: db.Read}
	resp, err := s.UsageSummary(UsageSummaryRequest{
		Period:  "2h",
		GroupBy: "queue",
		Now:     now,
	})
	if err != nil {
		t.Fatalf("UsageSummary() error: %v", err)
	}

	if resp.Totals.InputTokens != 210 || resp.Totals.OutputTokens != 35 || resp.Totals.Count != 3 {
		t.Fatalf("unexpected totals: %+v", resp.Totals)
	}
	if len(resp.Groups) != 2 {
		t.Fatalf("groups length = %d, want 2", len(resp.Groups))
	}
}

func TestUsageSummaryValidation(t *testing.T) {
	s := &Store{}
	if _, err := s.UsageSummary(UsageSummaryRequest{Period: "abc"}); err == nil {
		t.Fatalf("expected invalid period error")
	}

	dir := t.TempDir()
	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer func() { _ = db.Close() }()
	s = &Store{sqliteR: db.Read}
	if _, err := s.UsageSummary(UsageSummaryRequest{Period: "1h", GroupBy: "bad"}); err == nil {
		t.Fatalf("expected unsupported group_by error")
	}
}
