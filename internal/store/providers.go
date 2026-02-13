package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

type Provider struct {
	Name           string `json:"name"`
	RPMLimit       *int   `json:"rpm_limit,omitempty"`
	InputTPMLimit  *int   `json:"input_tpm_limit,omitempty"`
	OutputTPMLimit *int   `json:"output_tpm_limit,omitempty"`
	CreatedAt      string `json:"created_at"`
}

type SetProviderRequest struct {
	Name           string `json:"name"`
	RPMLimit       *int   `json:"rpm_limit,omitempty"`
	InputTPMLimit  *int   `json:"input_tpm_limit,omitempty"`
	OutputTPMLimit *int   `json:"output_tpm_limit,omitempty"`
}

func (s *Store) SetProvider(req SetProviderRequest) (*Provider, error) {
	name := strings.ToLower(strings.TrimSpace(req.Name))
	if name == "" {
		return nil, fmt.Errorf("name is required")
	}
	if req.RPMLimit != nil && *req.RPMLimit < 0 {
		return nil, fmt.Errorf("rpm_limit must be >= 0")
	}
	if req.InputTPMLimit != nil && *req.InputTPMLimit < 0 {
		return nil, fmt.Errorf("input_tpm_limit must be >= 0")
	}
	if req.OutputTPMLimit != nil && *req.OutputTPMLimit < 0 {
		return nil, fmt.Errorf("output_tpm_limit must be >= 0")
	}
	createdAt := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := s.sqliteR.Exec(`INSERT INTO providers (name, rpm_limit, input_tpm_limit, output_tpm_limit, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
			rpm_limit = excluded.rpm_limit,
			input_tpm_limit = excluded.input_tpm_limit,
			output_tpm_limit = excluded.output_tpm_limit`,
		name, req.RPMLimit, req.InputTPMLimit, req.OutputTPMLimit, createdAt,
	)
	if err != nil {
		return nil, err
	}
	return s.GetProvider(name)
}

func (s *Store) GetProvider(name string) (*Provider, error) {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		return nil, fmt.Errorf("name is required")
	}
	var p Provider
	err := s.sqliteR.QueryRow(`
		SELECT name, rpm_limit, input_tpm_limit, output_tpm_limit, created_at
		FROM providers WHERE name = ?`,
		name,
	).Scan(&p.Name, &p.RPMLimit, &p.InputTPMLimit, &p.OutputTPMLimit, &p.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("provider %q not found", name)
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

func (s *Store) ListProviders() ([]Provider, error) {
	rows, err := s.sqliteR.Query(`
		SELECT name, rpm_limit, input_tpm_limit, output_tpm_limit, created_at
		FROM providers ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Provider, 0)
	for rows.Next() {
		var p Provider
		if err := rows.Scan(&p.Name, &p.RPMLimit, &p.InputTPMLimit, &p.OutputTPMLimit, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) DeleteProvider(name string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		return fmt.Errorf("name is required")
	}
	_, err := s.sqliteR.Exec("DELETE FROM providers WHERE name = ?", name)
	if err != nil {
		return err
	}
	_, _ = s.sqliteR.Exec("UPDATE queues SET provider = NULL WHERE provider = ?", name)
	return nil
}

func (s *Store) SetQueueProvider(queue, provider string) error {
	queue = strings.TrimSpace(queue)
	provider = strings.ToLower(strings.TrimSpace(provider))
	if queue == "" {
		return fmt.Errorf("queue is required")
	}
	if provider != "" {
		if _, err := s.GetProvider(provider); err != nil {
			return err
		}
	}
	_, err := s.sqliteR.Exec("INSERT OR IGNORE INTO queues (name) VALUES (?)", queue)
	if err != nil {
		return err
	}
	var providerVal any
	if provider != "" {
		providerVal = provider
	}
	_, err = s.sqliteR.Exec("UPDATE queues SET provider = ? WHERE name = ?", providerVal, queue)
	return err
}
