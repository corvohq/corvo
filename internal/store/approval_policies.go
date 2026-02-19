package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type ApprovalPolicy struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Mode      string `json:"mode"` // any|all
	Enabled   bool   `json:"enabled"`
	Queue     string `json:"queue,omitempty"`
	TagKey    string `json:"tag_key,omitempty"`
	TagValue  string `json:"tag_value,omitempty"`
	CreatedAt string `json:"created_at"`
}

type SetApprovalPolicyRequest struct {
	Name     string `json:"name"`
	Mode     string `json:"mode,omitempty"` // any|all
	Enabled  *bool  `json:"enabled,omitempty"`
	Queue    string `json:"queue,omitempty"`
	TagKey   string `json:"tag_key,omitempty"`
	TagValue string `json:"tag_value,omitempty"`
}

func normalizeApprovalMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		return "any"
	}
	if mode != "any" && mode != "all" {
		return ""
	}
	return mode
}

func (s *Store) SetApprovalPolicy(req SetApprovalPolicyRequest) (*ApprovalPolicy, error) {
	name := strings.TrimSpace(req.Name)
	if name == "" {
		return nil, fmt.Errorf("name is required")
	}
	mode := normalizeApprovalMode(req.Mode)
	if mode == "" {
		return nil, fmt.Errorf("mode must be one of: any, all")
	}
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	id := "apol_" + newSortableID()
	createdAt := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := s.sqliteR.Exec(
		`INSERT INTO approval_policies
			(id, name, mode, enabled, queue, tag_key, tag_value, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, name, mode, boolInt(enabled), nullIfBlank(strings.TrimSpace(req.Queue)),
		nullIfBlank(strings.TrimSpace(req.TagKey)), nullIfBlank(strings.TrimSpace(req.TagValue)),
		createdAt,
	)
	if err != nil {
		return nil, err
	}
	return &ApprovalPolicy{
		ID:        id,
		Name:      name,
		Mode:      mode,
		Enabled:   enabled,
		Queue:     strings.TrimSpace(req.Queue),
		TagKey:    strings.TrimSpace(req.TagKey),
		TagValue:  strings.TrimSpace(req.TagValue),
		CreatedAt: createdAt,
	}, nil
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func nullIfBlank(v string) any {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return strings.TrimSpace(v)
}

func (s *Store) DeleteApprovalPolicy(id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return fmt.Errorf("id is required")
	}
	res, err := s.sqliteR.Exec("DELETE FROM approval_policies WHERE id = ?", id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("approval policy not found: %s", id)
	}
	return nil
}

func (s *Store) ListApprovalPolicies() ([]ApprovalPolicy, error) {
	rows, err := s.sqliteR.Query(`
		SELECT id, name, mode, enabled, queue, tag_key, tag_value, created_at
		FROM approval_policies
		ORDER BY created_at DESC, id DESC`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := make([]ApprovalPolicy, 0)
	for rows.Next() {
		var p ApprovalPolicy
		var enabled int
		var queue, tagKey, tagValue sql.NullString
		if err := rows.Scan(&p.ID, &p.Name, &p.Mode, &enabled, &queue, &tagKey, &tagValue, &p.CreatedAt); err != nil {
			return nil, err
		}
		p.Enabled = enabled == 1
		if queue.Valid {
			p.Queue = queue.String
		}
		if tagKey.Valid {
			p.TagKey = tagKey.String
		}
		if tagValue.Valid {
			p.TagValue = tagValue.String
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) evaluateApprovalPolicyHold(job *Job) (string, bool, error) {
	if job == nil {
		return "", false, nil
	}
	policies, err := s.ListApprovalPolicies()
	if err != nil {
		return "", false, err
	}
	if len(policies) == 0 {
		return "", false, nil
	}

	tags := map[string]string{}
	if len(job.Tags) > 0 {
		_ = json.Unmarshal(job.Tags, &tags)
	}

	for _, p := range policies {
		if !p.Enabled {
			continue
		}
		checks := make([]bool, 0, 2)
		if p.Queue != "" {
			checks = append(checks, p.Queue == job.Queue)
		}
		if p.TagKey != "" {
			checks = append(checks, tags[p.TagKey] == p.TagValue)
		}
		if len(checks) == 0 {
			continue
		}
		match := false
		if p.Mode == "all" {
			match = true
			for _, c := range checks {
				if !c {
					match = false
					break
				}
			}
		} else {
			for _, c := range checks {
				if c {
					match = true
					break
				}
			}
		}
		if match {
			reason := fmt.Sprintf("approval policy matched: %s", p.Name)
			return reason, true, nil
		}
	}
	return "", false, nil
}
