package server

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/user/corvo/internal/store"
)

type webhookConfig struct {
	ID             string     `json:"id"`
	URL            string     `json:"url"`
	Events         []string   `json:"events"`
	Secret         string     `json:"secret,omitempty"`
	Enabled        bool       `json:"enabled"`
	RetryLimit     int        `json:"retry_limit"`
	CreatedAt      time.Time  `json:"created_at,omitempty"`
	LastStatusCode *int       `json:"last_status_code,omitempty"`
	LastError      *string    `json:"last_error,omitempty"`
	LastDeliveryAt *time.Time `json:"last_delivery_at,omitempty"`
}

func (s *Server) listWebhooks() ([]webhookConfig, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT id, url, events, secret, enabled, retry_limit, created_at, last_status_code, last_error, last_delivery_at
		FROM webhooks
		ORDER BY created_at ASC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []webhookConfig{}
	for rows.Next() {
		var item webhookConfig
		var eventsJSON string
		var enabled int
		var createdAt string
		var status sql.NullInt64
		var lastErr sql.NullString
		var lastAt sql.NullString
		if err := rows.Scan(&item.ID, &item.URL, &eventsJSON, &item.Secret, &enabled, &item.RetryLimit, &createdAt, &status, &lastErr, &lastAt); err != nil {
			return nil, err
		}
		item.Enabled = enabled == 1
		item.CreatedAt = parseWebhookTime(createdAt)
		if strings.TrimSpace(eventsJSON) != "" {
			_ = json.Unmarshal([]byte(eventsJSON), &item.Events)
		}
		if status.Valid {
			v := int(status.Int64)
			item.LastStatusCode = &v
		}
		if lastErr.Valid {
			v := lastErr.String
			item.LastError = &v
		}
		if lastAt.Valid {
			t := parseWebhookTime(lastAt.String)
			item.LastDeliveryAt = &t
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Server) upsertWebhook(in webhookConfig) error {
	in.ID = strings.TrimSpace(in.ID)
	if in.ID == "" {
		in.ID = "wh_" + strings.ReplaceAll(strings.ToLower(store.NewJobID()), "job_", "")
	}
	in.URL = strings.TrimSpace(in.URL)
	if in.URL == "" {
		return fmt.Errorf("url is required")
	}
	if !strings.HasPrefix(in.URL, "http://") && !strings.HasPrefix(in.URL, "https://") {
		return fmt.Errorf("url must start with http:// or https://")
	}
	if len(in.Events) == 0 {
		in.Events = []string{"*"}
	}
	if in.RetryLimit <= 0 {
		in.RetryLimit = 3
	}
	eventsJSON, _ := json.Marshal(in.Events)
	_, err := s.store.ReadDB().Exec(`
		INSERT INTO webhooks (id, url, events, secret, enabled, retry_limit, created_at)
		VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f','now'))
		ON CONFLICT(id) DO UPDATE SET
			url = excluded.url,
			events = excluded.events,
			secret = excluded.secret,
			enabled = excluded.enabled,
			retry_limit = excluded.retry_limit
	`, in.ID, in.URL, string(eventsJSON), in.Secret, boolToInt(in.Enabled), in.RetryLimit)
	return err
}

func (s *Server) deleteWebhook(id string) error {
	_, err := s.store.ReadDB().Exec("DELETE FROM webhooks WHERE id = ?", id)
	return err
}

func (s *Server) webhookDispatcherLoop() {
	defer close(s.webhookDone)
	if s.cluster == nil {
		return
	}
	lastSeq := uint64(0)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-s.webhookStop:
			return
		case <-ticker.C:
			if !s.cluster.IsLeader() {
				continue
			}
			events, err := s.cluster.EventLog(lastSeq, 100)
			if err != nil || len(events) == 0 {
				continue
			}
			hooks, err := s.listWebhooks()
			if err != nil || len(hooks) == 0 {
				for _, ev := range events {
					if v, ok := toUint64(ev["seq"]); ok && v > lastSeq {
						lastSeq = v
					}
				}
				continue
			}
			for _, ev := range events {
				if v, ok := toUint64(ev["seq"]); ok && v > lastSeq {
					lastSeq = v
				}
				for _, h := range hooks {
					if !h.Enabled {
						continue
					}
					if !webhookMatchesEvent(h.Events, asString(ev["type"])) {
						continue
					}
					go s.deliverWebhook(h, ev)
				}
			}
		}
	}
}

func webhookMatchesEvent(events []string, typ string) bool {
	if len(events) == 0 {
		return false
	}
	for _, e := range events {
		e = strings.TrimSpace(e)
		if e == "*" || strings.EqualFold(e, typ) {
			return true
		}
	}
	return false
}

func (s *Server) deliverWebhook(h webhookConfig, ev map[string]any) {
	payload := map[string]any{
		"webhook_id": h.ID,
		"event":      ev,
		"sent_at":    time.Now().UTC().Format(time.RFC3339Nano),
	}
	body, _ := json.Marshal(payload)
	maxAttempts := h.RetryLimit
	if maxAttempts <= 0 {
		maxAttempts = 3
	}
	lastErr := ""
	statusCode := 0
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		req, _ := http.NewRequest(http.MethodPost, h.URL, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Corvo-Webhook-ID", h.ID)
		req.Header.Set("X-Corvo-Webhook-Event", asString(ev["type"]))
		if h.Secret != "" {
			sig := hmac.New(sha256.New, []byte(h.Secret))
			_, _ = sig.Write(body)
			req.Header.Set("X-Corvo-Signature", "sha256="+hex.EncodeToString(sig.Sum(nil)))
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			lastErr = err.Error()
			time.Sleep(time.Duration(attempt*attempt) * 200 * time.Millisecond)
			continue
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		statusCode = resp.StatusCode
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			lastErr = ""
			break
		}
		lastErr = fmt.Sprintf("http %d", resp.StatusCode)
		time.Sleep(time.Duration(attempt*attempt) * 200 * time.Millisecond)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	var errVal any
	if lastErr == "" {
		errVal = nil
	} else {
		errVal = lastErr
	}
	_, err := s.store.ReadDB().Exec(
		"UPDATE webhooks SET last_status_code = ?, last_error = ?, last_delivery_at = ? WHERE id = ?",
		statusCode, errVal, now, h.ID,
	)
	if err != nil {
		slog.Debug("webhook status update failed", "id", h.ID, "error", err)
	}
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}

func toUint64(v any) (uint64, bool) {
	switch x := v.(type) {
	case uint64:
		return x, true
	case int64:
		if x < 0 {
			return 0, false
		}
		return uint64(x), true
	case float64:
		if x < 0 {
			return 0, false
		}
		return uint64(x), true
	default:
		return 0, false
	}
}

func parseWebhookTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t
	}
	if t, err := time.Parse("2006-01-02T15:04:05.000", s); err == nil {
		return t.UTC()
	}
	return time.Time{}
}
