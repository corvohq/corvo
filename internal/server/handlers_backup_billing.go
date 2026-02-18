package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/corvohq/corvo/internal/store"
)

type tenantBackup struct {
	Namespace string           `json:"namespace"`
	CreatedAt string           `json:"created_at"`
	Jobs      []store.Job      `json:"jobs"`
	Queues    []store.Queue    `json:"queues"`
	Budgets   []map[string]any `json:"budgets,omitempty"`
	Meta      map[string]any   `json:"meta,omitempty"`
}

func (s *Server) handleTenantBackup(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	ns := strings.TrimSpace(r.URL.Query().Get("namespace"))
	if ns == "" {
		ns = principal.Namespace
	}
	prefix := ""
	if ns != "" && ns != "default" {
		prefix = ns + "::"
	}
	out := tenantBackup{Namespace: ns, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Meta: map[string]any{"format": 1}}

	rows, err := s.store.ReadDB().Query(`
		SELECT id, queue, state, payload, priority, attempt, max_retries,
			retry_backoff, retry_base_delay_ms, retry_max_delay_ms,
			tags, checkpoint, result, chain_config, created_at, started_at, completed_at, failed_at
		FROM jobs ORDER BY created_at ASC
	`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "BACKUP_ERROR")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var j store.Job
		var payload, tags, checkpoint, result, chainCfg string
		var createdAt string
		var startedAt, completedAt, failedAt *string
		if err := rows.Scan(
			&j.ID, &j.Queue, &j.State, &payload, &j.Priority, &j.Attempt, &j.MaxRetries,
			&j.RetryBackoff, &j.RetryBaseDelay, &j.RetryMaxDelay,
			&tags, &checkpoint, &result, &chainCfg, &createdAt, &startedAt, &completedAt, &failedAt,
		); err != nil {
			continue
		}
		if prefix != "" && !strings.HasPrefix(j.Queue, prefix) {
			continue
		}
		j.Queue = visibleQueue(ns, j.Queue)
		j.Payload = json.RawMessage(payload)
		j.Tags = json.RawMessage(tags)
		j.Checkpoint = json.RawMessage(checkpoint)
		j.Result = json.RawMessage(result)
		j.ChainConfig = json.RawMessage(chainCfg)
		j.CreatedAt = parseWebhookTime(createdAt)
		out.Jobs = append(out.Jobs, j)
	}

	queues, _ := s.store.ListQueues()
	for _, q := range queues {
		if prefix != "" && !strings.HasPrefix(q.Name, prefix) {
			continue
		}
		name := visibleQueue(ns, q.Name)
		out.Queues = append(out.Queues, store.Queue{Name: name, Paused: q.Paused, MaxConcurrency: q.MaxConcurrency, RateLimit: q.RateLimit, RateWindowMs: q.RateWindowMs, CreatedAt: q.CreatedAt})
	}

	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleTenantRestore(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var req tenantBackup
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	ns := strings.TrimSpace(req.Namespace)
	if ns == "" {
		ns = principal.Namespace
	}
	restored := 0
	for _, j := range req.Jobs {
		_, err := s.store.Enqueue(store.EnqueueRequest{
			Queue:       namespaceQueue(ns, j.Queue),
			Payload:     j.Payload,
			Priority:    store.PriorityToString(j.Priority),
			Tags:        j.Tags,
			Checkpoint:  j.Checkpoint,
			ChainConfig: j.ChainConfig,
		})
		if err == nil {
			restored++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "restored_jobs": restored, "namespace": ns})
}

func (s *Server) handleBillingSummary(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	period := strings.TrimSpace(r.URL.Query().Get("period"))
	if period == "" {
		period = "24h"
	}
	dur, err := time.ParseDuration(period)
	if err != nil || dur <= 0 {
		writeError(w, http.StatusBadRequest, "invalid period", "VALIDATION_ERROR")
		return
	}
	cutoff := time.Now().Add(-dur).UTC().Format(time.RFC3339Nano)

	rows, err := s.store.ReadDB().Query(`
		SELECT queue,
			COALESCE(SUM(input_tokens), 0),
			COALESCE(SUM(output_tokens), 0),
			COALESCE(SUM(cache_creation_tokens), 0),
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(cost_usd), 0),
			COUNT(*)
		FROM job_usage
		WHERE created_at >= ?
		GROUP BY queue
	`, cutoff)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "BILLING_ERROR")
		return
	}
	defer rows.Close()
	type agg struct {
		Rows                int64   `json:"rows"`
		InputTokens         int64   `json:"input_tokens"`
		OutputTokens        int64   `json:"output_tokens"`
		CacheCreationTokens int64   `json:"cache_creation_tokens"`
		CacheReadTokens     int64   `json:"cache_read_tokens"`
		CostUSD             float64 `json:"cost_usd"`
	}
	out := map[string]agg{}
	for rows.Next() {
		var queue string
		var a agg
		if err := rows.Scan(&queue, &a.InputTokens, &a.OutputTokens, &a.CacheCreationTokens, &a.CacheReadTokens, &a.CostUSD, &a.Rows); err != nil {
			continue
		}
		ns := extractNamespaceFromQueue(queue)
		if principal.Namespace != "" && principal.Namespace != "default" && ns != principal.Namespace {
			continue
		}
		curr := out[ns]
		curr.Rows += a.Rows
		curr.InputTokens += a.InputTokens
		curr.OutputTokens += a.OutputTokens
		curr.CacheCreationTokens += a.CacheCreationTokens
		curr.CacheReadTokens += a.CacheReadTokens
		curr.CostUSD += a.CostUSD
		out[ns] = curr
	}
	resp := []map[string]any{}
	for ns, a := range out {
		resp = append(resp, map[string]any{
			"namespace":             ns,
			"rows":                  a.Rows,
			"input_tokens":          a.InputTokens,
			"output_tokens":         a.OutputTokens,
			"cache_creation_tokens": a.CacheCreationTokens,
			"cache_read_tokens":     a.CacheReadTokens,
			"cost_usd":              a.CostUSD,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"period": period, "summary": resp})
}

func extractNamespaceFromQueue(queue string) string {
	idx := strings.Index(queue, "::")
	if idx <= 0 {
		return "default"
	}
	return queue[:idx]
}

func intQueryParam(raw string, def int) int {
	if strings.TrimSpace(raw) == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return v
}

func namespaceFromRequestOrPrincipal(reqNs string, principal authPrincipal) string {
	ns := strings.TrimSpace(reqNs)
	if ns == "" {
		ns = principal.Namespace
	}
	if ns == "" {
		ns = "default"
	}
	return ns
}

func fmtErrf(format string, args ...any) error {
	return fmt.Errorf(format, args...)
}
