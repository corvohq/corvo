package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

const (
	BudgetScopeQueue  = "queue"
	BudgetScopeTag    = "tag"
	BudgetScopeGlobal = "global"

	BudgetOnExceedHold      = "hold"
	BudgetOnExceedReject    = "reject"
	BudgetOnExceedAlertOnly = "alert_only"
)

type Budget struct {
	ID        string   `json:"id"`
	Scope     string   `json:"scope"`
	Target    string   `json:"target"`
	DailyUSD  *float64 `json:"daily_usd,omitempty"`
	PerJobUSD *float64 `json:"per_job_usd,omitempty"`
	OnExceed  string   `json:"on_exceed"`
	CreatedAt string   `json:"created_at"`
}

type SetBudgetRequest struct {
	Scope     string   `json:"scope"`
	Target    string   `json:"target"`
	DailyUSD  *float64 `json:"daily_usd,omitempty"`
	PerJobUSD *float64 `json:"per_job_usd,omitempty"`
	OnExceed  string   `json:"on_exceed,omitempty"`
}

func normalizeBudget(scope, target, onExceed string) (string, string, string, error) {
	scope = strings.ToLower(strings.TrimSpace(scope))
	target = strings.TrimSpace(target)
	onExceed = strings.ToLower(strings.TrimSpace(onExceed))
	if onExceed == "" {
		onExceed = BudgetOnExceedHold
	}
	switch scope {
	case BudgetScopeQueue, BudgetScopeTag:
		if target == "" {
			return "", "", "", fmt.Errorf("target is required for scope %q", scope)
		}
	case BudgetScopeGlobal:
		if target == "" {
			target = "*"
		}
	default:
		return "", "", "", fmt.Errorf("invalid budget scope: %q", scope)
	}
	switch onExceed {
	case BudgetOnExceedHold, BudgetOnExceedReject, BudgetOnExceedAlertOnly:
	default:
		return "", "", "", fmt.Errorf("invalid on_exceed: %q", onExceed)
	}
	return scope, target, onExceed, nil
}

func (s *Store) SetBudget(req SetBudgetRequest) (*Budget, error) {
	scope, target, onExceed, err := normalizeBudget(req.Scope, req.Target, req.OnExceed)
	if err != nil {
		return nil, err
	}
	if req.DailyUSD != nil && *req.DailyUSD < 0 {
		return nil, fmt.Errorf("daily_usd must be >= 0")
	}
	if req.PerJobUSD != nil && *req.PerJobUSD < 0 {
		return nil, fmt.Errorf("per_job_usd must be >= 0")
	}
	if req.DailyUSD == nil && req.PerJobUSD == nil {
		return nil, fmt.Errorf("at least one limit is required (daily_usd or per_job_usd)")
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	op := SetBudgetOp{
		ID:        "budget_" + newSortableID(),
		Scope:     scope,
		Target:    target,
		DailyUSD:  req.DailyUSD,
		PerJobUSD: req.PerJobUSD,
		OnExceed:  onExceed,
		CreatedAt: now,
	}
	if err := s.applyOpConsistent(OpSetBudget, op).Err; err != nil {
		return nil, err
	}
	s.budgetConfigState.Store(1)
	return &Budget{
		ID:        op.ID,
		Scope:     op.Scope,
		Target:    op.Target,
		DailyUSD:  op.DailyUSD,
		PerJobUSD: op.PerJobUSD,
		OnExceed:  op.OnExceed,
		CreatedAt: op.CreatedAt,
	}, nil
}

func (s *Store) DeleteBudget(scope, target string) error {
	scope, target, _, err := normalizeBudget(scope, target, BudgetOnExceedHold)
	if err != nil {
		return err
	}
	if err := s.applyOpConsistent(OpDeleteBudget, DeleteBudgetOp{Scope: scope, Target: target}).Err; err != nil {
		return err
	}
	s.refreshBudgetConfigState()
	return nil
}

func (s *Store) GetBudget(scope, target string) (*Budget, error) {
	scope = strings.ToLower(strings.TrimSpace(scope))
	target = strings.TrimSpace(target)
	var b Budget
	err := s.sqliteR.QueryRow(`
		SELECT id, scope, target, daily_usd, per_job_usd, on_exceed, created_at
		FROM budgets WHERE scope = ? AND target = ?`,
		scope, target,
	).Scan(&b.ID, &b.Scope, &b.Target, &b.DailyUSD, &b.PerJobUSD, &b.OnExceed, &b.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("budget not found for %s:%s", scope, target)
	}
	if err != nil {
		return nil, err
	}
	return &b, nil
}

func (s *Store) ListBudgets() ([]Budget, error) {
	rows, err := s.sqliteR.Query(`
		SELECT id, scope, target, daily_usd, per_job_usd, on_exceed, created_at
		FROM budgets
		ORDER BY scope, target`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := make([]Budget, 0)
	for rows.Next() {
		var b Budget
		if err := rows.Scan(&b.ID, &b.Scope, &b.Target, &b.DailyUSD, &b.PerJobUSD, &b.OnExceed, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) enforceFetchBudgets(queues []string) ([]string, error) {
	if len(queues) == 0 {
		return queues, nil
	}
	if !s.hasAnyBudgetsConfigured() {
		return queues, nil
	}
	allowed := make([]string, 0, len(queues))
	for _, queue := range queues {
		ok, err := s.queueAllowedByBudget(queue)
		if err != nil {
			return nil, err
		}
		if ok {
			allowed = append(allowed, queue)
		}
	}
	return allowed, nil
}

func (s *Store) hasAnyBudgetsConfigured() bool {
	switch s.budgetConfigState.Load() {
	case 0:
		return false
	case 1:
		return true
	default:
		return s.refreshBudgetConfigState()
	}
}

func (s *Store) refreshBudgetConfigState() bool {
	if s.sqliteR == nil {
		s.budgetConfigState.Store(0)
		return false
	}
	var one int
	err := s.sqliteR.QueryRow("SELECT 1 FROM budgets LIMIT 1").Scan(&one)
	if err == sql.ErrNoRows {
		s.budgetConfigState.Store(0)
		return false
	}
	if err != nil {
		// Fail-open: preserve behavior when sqlite mirror is temporarily unavailable.
		s.budgetConfigState.Store(1)
		return true
	}
	s.budgetConfigState.Store(1)
	return true
}

func (s *Store) queueAllowedByBudget(queue string) (bool, error) {
	budgets, err := s.fetchQueueBudgets(queue)
	if err != nil {
		return false, err
	}
	if len(budgets) == 0 {
		return true, nil
	}
	dayStart := time.Now().UTC().Truncate(24 * time.Hour).Format(time.RFC3339Nano)
	var spent float64
	if err := s.sqliteR.QueryRow(`
		SELECT COALESCE(SUM(cost_usd), 0)
		FROM job_usage
		WHERE queue = ? AND created_at >= ?`,
		queue, dayStart,
	).Scan(&spent); err != nil {
		return false, err
	}
	var avgCost float64
	if err := s.sqliteR.QueryRow(`
		SELECT COALESCE(AVG(cost_usd), 0)
		FROM job_usage
		WHERE queue = ? AND phase = 'ack'`,
		queue,
	).Scan(&avgCost); err != nil {
		return false, err
	}

	exceeded := false
	action := BudgetOnExceedAlertOnly
	for _, b := range budgets {
		if b.DailyUSD != nil && spent >= *b.DailyUSD {
			exceeded = true
			action = stricterBudgetAction(action, b.OnExceed)
		}
		if b.PerJobUSD != nil && avgCost > *b.PerJobUSD && avgCost > 0 {
			exceeded = true
			action = stricterBudgetAction(action, b.OnExceed)
		}
	}
	if !exceeded {
		return true, nil
	}
	switch action {
	case BudgetOnExceedReject:
		return false, NewBudgetExceededError(fmt.Sprintf("budget exceeded for queue %q", queue))
	case BudgetOnExceedHold:
		_, _ = s.holdOnePendingInQueue(queue)
		return false, nil
	default:
		return true, nil
	}
}

func (s *Store) fetchQueueBudgets(queue string) ([]Budget, error) {
	rows, err := s.sqliteR.Query(`
		SELECT id, scope, target, daily_usd, per_job_usd, on_exceed, created_at
		FROM budgets
		WHERE (scope = 'queue' AND target = ?)
		   OR (scope = 'global' AND target = '*')`,
		queue,
	)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := make([]Budget, 0)
	for rows.Next() {
		var b Budget
		if err := rows.Scan(&b.ID, &b.Scope, &b.Target, &b.DailyUSD, &b.PerJobUSD, &b.OnExceed, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) holdOnePendingInQueue(queue string) (string, error) {
	var id string
	if err := s.sqliteR.QueryRow(`
		SELECT id FROM jobs
		WHERE queue = ? AND state = 'pending'
		ORDER BY created_at ASC
		LIMIT 1`,
		queue,
	).Scan(&id); err != nil {
		if err == sql.ErrNoRows {
			return "", nil
		}
		return "", err
	}
	return id, s.HoldJob(id)
}

func (s *Store) evaluatePerJobBudget(jobID string, incomingCost float64) (bool, string, error) {
	var queue string
	var tagsRaw sql.NullString
	if err := s.sqliteR.QueryRow("SELECT queue, tags FROM jobs WHERE id = ?", jobID).Scan(&queue, &tagsRaw); err != nil {
		if err == sql.ErrNoRows {
			// SQLite mirror can lag behind the latest Raft state; avoid
			// rejecting ACKs due to transient read-side misses.
			return false, "", nil
		}
		return false, "", err
	}
	tags := map[string]string{}
	if tagsRaw.Valid && strings.TrimSpace(tagsRaw.String) != "" {
		_ = json.Unmarshal([]byte(tagsRaw.String), &tags)
	}

	rows, err := s.sqliteR.Query(`
		SELECT id, scope, target, daily_usd, per_job_usd, on_exceed, created_at
		FROM budgets
		WHERE per_job_usd IS NOT NULL`)
	if err != nil {
		return false, "", err
	}
	defer func() { _ = rows.Close() }()

	var matched []Budget
	for rows.Next() {
		var b Budget
		if err := rows.Scan(&b.ID, &b.Scope, &b.Target, &b.DailyUSD, &b.PerJobUSD, &b.OnExceed, &b.CreatedAt); err != nil {
			return false, "", err
		}
		switch b.Scope {
		case BudgetScopeGlobal:
			if b.Target == "*" {
				matched = append(matched, b)
			}
		case BudgetScopeQueue:
			if b.Target == queue {
				matched = append(matched, b)
			}
		case BudgetScopeTag:
			if tagBudgetMatches(tags, b.Target) {
				matched = append(matched, b)
			}
		}
	}
	if err := rows.Err(); err != nil {
		return false, "", err
	}
	if len(matched) == 0 {
		return false, "", nil
	}

	var total float64
	if err := s.sqliteR.QueryRow(`
		SELECT COALESCE(SUM(cost_usd), 0)
		FROM job_usage
		WHERE job_id = ?`,
		jobID,
	).Scan(&total); err != nil {
		return false, "", err
	}
	total += incomingCost

	var limit *float64
	action := BudgetOnExceedAlertOnly
	for _, b := range matched {
		if b.PerJobUSD == nil {
			continue
		}
		if limit == nil || *b.PerJobUSD < *limit {
			limit = b.PerJobUSD
			action = b.OnExceed
			continue
		}
		if *b.PerJobUSD == *limit {
			action = stricterBudgetAction(action, b.OnExceed)
		}
	}
	if limit == nil {
		return false, "", nil
	}
	return total > *limit, action, nil
}

func tagBudgetMatches(tags map[string]string, target string) bool {
	target = strings.TrimSpace(target)
	if target == "" {
		return false
	}
	var key, val string
	if i := strings.Index(target, ":"); i > 0 {
		key, val = target[:i], target[i+1:]
	} else if i := strings.Index(target, "="); i > 0 {
		key, val = target[:i], target[i+1:]
	}
	if key == "" {
		return false
	}
	return tags[key] == val
}

func stricterBudgetAction(current, next string) string {
	rank := func(a string) int {
		switch a {
		case BudgetOnExceedReject:
			return 3
		case BudgetOnExceedHold:
			return 2
		default:
			return 1
		}
	}
	if rank(next) > rank(current) {
		return next
	}
	return current
}
