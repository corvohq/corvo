package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/spf13/cobra"
)

var (
	seedCount int
)

var seedCmd = &cobra.Command{
	Use:   "seed",
	Short: "Seed demo data for development",
}

var seedDemoCmd = &cobra.Command{
	Use:          "demo",
	Short:        "Seed AI/agent demo data for dashboards and job detail",
	SilenceUsage: true,
	RunE: func(cmd *cobra.Command, args []string) error {
		if seedCount <= 0 {
			return fmt.Errorf("--count must be > 0")
		}
		agentQueue := "agents.seed"

		// Budgets (safe to upsert repeatedly).
		if err := postOK("/api/v1/budgets", map[string]any{
			"scope":     "global",
			"target":    "*",
			"daily_usd": 25.0,
			"on_exceed": "alert_only",
		}); err != nil {
			return err
		}
		if err := postOK("/api/v1/providers", map[string]any{
			"name":             "anthropic",
			"rpm_limit":        4000,
			"input_tpm_limit":  400000,
			"output_tpm_limit": 80000,
		}); err != nil {
			return err
		}
		if err := postOK("/api/v1/providers", map[string]any{
			"name":            "openai",
			"rpm_limit":       10000,
			"input_tpm_limit": 2000000,
		}); err != nil {
			return err
		}
		_ = postOK("/api/v1/queues/agents.research/provider", map[string]any{"provider": "anthropic"})
		if err := postOK("/api/v1/budgets", map[string]any{
			"scope":       "queue",
			"target":      agentQueue,
			"daily_usd":   10.0,
			"per_job_usd": 1.25,
			"on_exceed":   "hold",
		}); err != nil {
			return err
		}

		type enqueueResult struct {
			JobID string `json:"job_id"`
		}
		var seededIDs []string
		queues := []string{"emails.send", "reports.generate", "agents.research"}
		models := []string{"claude-sonnet-4-5", "gpt-4.1", "gpt-4o-mini"}
		providers := []string{"anthropic", "openai", "openai"}

		// General jobs with usage/cost data.
		for i := 0; i < seedCount; i++ {
			queue := queues[i%len(queues)]
			body := map[string]any{
				"queue": queue,
				"payload": map[string]any{
					"type":      "seed",
					"index":     i,
					"recipient": fmt.Sprintf("user-%03d@example.com", i),
				},
				"tags": map[string]any{
					"tenant": fmt.Sprintf("tenant-%d", (i%3)+1),
				},
			}
			var enq enqueueResult
			if err := postDecode("/api/v1/enqueue", body, &enq); err != nil {
				return err
			}
			if enq.JobID == "" {
				continue
			}
			seededIDs = append(seededIDs, enq.JobID)

			// Fetch and ack about 80% to produce usage data; leave others pending/active.
			if i%5 != 0 {
				jobID, err := fetchOne(queue)
				if err != nil {
					return err
				}
				if jobID != "" {
					model := models[i%len(models)]
					provider := providers[i%len(providers)]
					cost := 0.004 + float64((i%7))*0.0013
					ackBody := map[string]any{
						"result": map[string]any{
							"ok":      true,
							"summary": fmt.Sprintf("processed seed job %d", i),
						},
						"usage": map[string]any{
							"input_tokens":          900 + (i * 11),
							"output_tokens":         200 + (i * 7),
							"cache_creation_tokens": 80 + (i % 20),
							"cache_read_tokens":     120 + (i % 40),
							"model":                 model,
							"provider":              provider,
							"cost_usd":              cost,
						},
					}
					if err := postOK("/api/v1/ack/"+jobID, ackBody); err != nil {
						return err
					}
				}
			}
		}

		// Dead jobs for DLQ page.
		for i := 0; i < 6; i++ {
			var enq enqueueResult
			if err := postDecode("/api/v1/enqueue", map[string]any{
				"queue":       "emails.send",
				"payload":     map[string]any{"type": "seed-dead", "index": i},
				"max_retries": 0,
			}, &enq); err != nil {
				return err
			}
			jobID, err := fetchOne("emails.send")
			if err != nil {
				return err
			}
			if jobID == "" {
				continue
			}
			if err := postOK("/api/v1/fail/"+jobID, map[string]any{
				"error": fmt.Sprintf("seed failure %d", i),
			}); err != nil {
				return err
			}
		}

		// Scheduled jobs.
		for i := 0; i < 5; i++ {
			sched := time.Now().UTC().Add(time.Duration(10+i) * time.Minute).Format(time.RFC3339)
			if err := postOK("/api/v1/enqueue", map[string]any{
				"queue":        "reports.generate",
				"payload":      map[string]any{"type": "seed-scheduled", "index": i},
				"scheduled_at": sched,
			}); err != nil {
				return err
			}
		}

		// Held job from explicit hold action.
		var holdEnq enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   "agents.research",
			"payload": map[string]any{"type": "seed-held-manual"},
		}, &holdEnq); err != nil {
			return err
		}
		if holdEnq.JobID != "" {
			if err := postOK("/api/v1/jobs/"+holdEnq.JobID+"/hold", nil); err != nil {
				return err
			}
		}

		// Agent job with iterations + done state (for job detail page).
		var agentEnq enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue": agentQueue,
			"payload": map[string]any{
				"goal": "Find top competitors and summarize",
			},
			"agent": map[string]any{
				"max_iterations":    8,
				"max_cost_usd":      2.0,
				"iteration_timeout": "2m",
			},
			"tags": map[string]any{"tenant": "demo-agent"},
		}, &agentEnq); err != nil {
			return err
		}
		for i := 1; i <= 2; i++ {
			jobID, err := fetchOne(agentQueue)
			if err != nil {
				return err
			}
			if jobID == "" {
				break
			}
			if err := postOK("/api/v1/ack/"+jobID, map[string]any{
				"agent_status": "continue",
				"checkpoint": map[string]any{
					"iteration": i,
					"messages":  []string{fmt.Sprintf("iteration %d notes", i)},
				},
				"usage": map[string]any{
					"input_tokens":  1800 + i*200,
					"output_tokens": 420 + i*70,
					"model":         "claude-sonnet-4-5",
					"provider":      "anthropic",
					"cost_usd":      0.018 + float64(i)*0.004,
				},
			}); err != nil {
				return err
			}
		}
		{
			jobID, err := fetchOne(agentQueue)
			if err != nil {
				return err
			}
			if jobID != "" {
				if err := postOK("/api/v1/ack/"+jobID, map[string]any{
					"agent_status": "done",
					"result": map[string]any{
						"summary": "Top competitors identified with market positioning.",
						"output":  "Competitor A, B, C with concise differentiation notes...",
						"scores": map[string]any{
							"relevance": 0.94,
							"grounding": 0.89,
						},
					},
					"usage": map[string]any{
						"input_tokens":  1500,
						"output_tokens": 800,
						"model":         "claude-sonnet-4-5",
						"provider":      "anthropic",
						"cost_usd":      0.024,
					},
				}); err != nil {
					return err
				}
			}
		}
		if agentEnq.JobID != "" {
			_ = postOK("/api/v1/scores", map[string]any{
				"job_id":    agentEnq.JobID,
				"dimension": "relevance",
				"value":     0.94,
				"scorer":    "auto:seed",
			})
			_ = postOK("/api/v1/scores", map[string]any{
				"job_id":    agentEnq.JobID,
				"dimension": "grounding",
				"value":     0.89,
				"scorer":    "auto:seed",
			})
		}

		// Agent job forced to held by guardrail.
		var guardrailEnq enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   agentQueue,
			"payload": map[string]any{"goal": "force guardrail hold"},
			"agent": map[string]any{
				"max_iterations": 1,
				"max_cost_usd":   10.0,
			},
		}, &guardrailEnq); err != nil {
			return err
		}
		{
			jobID, err := fetchOne(agentQueue)
			if err != nil {
				return err
			}
			if jobID != "" {
				if err := postOK("/api/v1/ack/"+jobID, map[string]any{
					"agent_status": "continue",
					"checkpoint":   map[string]any{"iteration": 1},
					"usage": map[string]any{
						"model":    "gpt-4.1",
						"provider": "openai",
						"cost_usd": 0.011,
					},
				}); err != nil {
					return err
				}
			}
		}

		fmt.Printf("Seeded demo data successfully.\n")
		fmt.Printf("- base jobs requested: %d\n", seedCount)
		fmt.Printf("- seeded job IDs tracked: %d\n", len(seededIDs))
		if agentEnq.JobID != "" {
			fmt.Printf("- agent detail job: %s\n", agentEnq.JobID)
		}
		if holdEnq.JobID != "" {
			fmt.Printf("- manual held job: %s\n", holdEnq.JobID)
		}
		if guardrailEnq.JobID != "" {
			fmt.Printf("- guardrail-held agent: %s\n", guardrailEnq.JobID)
		}
		return nil
	},
}

func postOK(path string, body any) error {
	data, status, err := apiRequest("POST", path, body)
	if err != nil {
		return err
	}
	if status >= 400 {
		return fmt.Errorf("POST %s failed (%d): %s", path, status, string(data))
	}
	return nil
}

func postDecode(path string, body any, out any) error {
	data, status, err := apiRequest("POST", path, body)
	if err != nil {
		return err
	}
	if status >= 400 {
		return fmt.Errorf("POST %s failed (%d): %s", path, status, string(data))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("decode POST %s response: %w", path, err)
	}
	return nil
}

func fetchOne(queue string) (string, error) {
	var out struct {
		JobID string `json:"job_id"`
	}
	data, status, err := apiRequest("POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{queue},
		"worker_id": "seed-worker",
		"hostname":  "seed-host",
		"timeout":   1,
	})
	if err != nil {
		return "", err
	}
	if status == 204 {
		return "", nil
	}
	if status >= 400 {
		return "", fmt.Errorf("fetch %s failed (%d): %s", queue, status, string(data))
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", err
	}
	return out.JobID, nil
}

func init() {
	seedDemoCmd.Flags().IntVar(&seedCount, "count", 48, "Number of baseline seeded jobs")
	addClientFlags(seedDemoCmd)
	seedCmd.AddCommand(seedDemoCmd)
	rootCmd.AddCommand(seedCmd)
}
