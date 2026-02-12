package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// HeartbeatJobUpdate contains per-job heartbeat data.
type HeartbeatJobUpdate struct {
	Progress   map[string]interface{} `json:"progress,omitempty"`
	Checkpoint map[string]interface{} `json:"checkpoint,omitempty"`
}

// HeartbeatRequest contains the batched heartbeat data for all active jobs on a worker.
type HeartbeatRequest struct {
	Jobs map[string]HeartbeatJobUpdate `json:"jobs"`
}

// HeartbeatJobResponse is the per-job heartbeat response.
type HeartbeatJobResponse struct {
	Status string `json:"status"` // "ok" or "cancel"
}

// HeartbeatResponse is the batched heartbeat response.
type HeartbeatResponse struct {
	Jobs map[string]HeartbeatJobResponse `json:"jobs"`
}

// Heartbeat extends leases, updates progress/checkpoint, and returns cancel signals.
func (s *Store) Heartbeat(req HeartbeatRequest) (*HeartbeatResponse, error) {
	resp := &HeartbeatResponse{
		Jobs: make(map[string]HeartbeatJobResponse, len(req.Jobs)),
	}

	err := s.writer.ExecuteTx(func(tx *sql.Tx) error {
		now := time.Now().UTC()

		for jobID, update := range req.Jobs {
			var state string
			err := tx.QueryRow("SELECT state FROM jobs WHERE id = ?", jobID).Scan(&state)
			if err == sql.ErrNoRows {
				resp.Jobs[jobID] = HeartbeatJobResponse{Status: "cancel"}
				continue
			}
			if err != nil {
				return fmt.Errorf("read job %s: %w", jobID, err)
			}

			if state != StateActive {
				resp.Jobs[jobID] = HeartbeatJobResponse{Status: "cancel"}
				continue
			}

			leaseExpires := now.Add(60 * time.Second).Format(time.RFC3339Nano)

			if update.Progress != nil && update.Checkpoint != nil {
				progressJSON, _ := json.Marshal(update.Progress)
				checkpointJSON, _ := json.Marshal(update.Checkpoint)
				_, err = tx.Exec("UPDATE jobs SET progress = ?, checkpoint = ?, lease_expires_at = ? WHERE id = ?",
					string(progressJSON), string(checkpointJSON), leaseExpires, jobID)
			} else if update.Progress != nil {
				progressJSON, _ := json.Marshal(update.Progress)
				_, err = tx.Exec("UPDATE jobs SET progress = ?, lease_expires_at = ? WHERE id = ?",
					string(progressJSON), leaseExpires, jobID)
			} else if update.Checkpoint != nil {
				checkpointJSON, _ := json.Marshal(update.Checkpoint)
				_, err = tx.Exec("UPDATE jobs SET checkpoint = ?, lease_expires_at = ? WHERE id = ?",
					string(checkpointJSON), leaseExpires, jobID)
			} else {
				_, err = tx.Exec("UPDATE jobs SET lease_expires_at = ? WHERE id = ?",
					leaseExpires, jobID)
			}
			if err != nil {
				return fmt.Errorf("update job %s: %w", jobID, err)
			}

			resp.Jobs[jobID] = HeartbeatJobResponse{Status: "ok"}
		}

		// Update worker last_heartbeat
		if len(req.Jobs) > 0 {
			for jobID := range req.Jobs {
				var workerID sql.NullString
				tx.QueryRow("SELECT worker_id FROM jobs WHERE id = ?", jobID).Scan(&workerID)
				if workerID.Valid {
					_, _ = tx.Exec("UPDATE workers SET last_heartbeat = ? WHERE id = ?",
						now.Format(time.RFC3339Nano), workerID.String)
					break
				}
			}
		}

		return nil
	})

	if err != nil {
		return nil, err
	}

	return resp, nil
}
