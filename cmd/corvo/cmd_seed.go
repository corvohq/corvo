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
		priorities := []string{"normal", "normal", "high", "low", "critical"}

		// General jobs with usage/cost data, priorities, and retry configs.
		for i := 0; i < seedCount; i++ {
			queue := queues[i%len(queues)]
			body := map[string]any{
				"queue":    queue,
				"priority": priorities[i%len(priorities)],
				"payload": map[string]any{
					"type":      "seed",
					"index":     i,
					"recipient": fmt.Sprintf("user-%03d@example.com", i),
				},
				"tags": map[string]any{
					"tenant": fmt.Sprintf("tenant-%d", (i%3)+1),
				},
			}
			// Add retry config to some jobs.
			if i%8 == 0 {
				body["retry_backoff"] = "exponential"
				body["retry_base_delay"] = "2s"
				body["retry_max_delay"] = "5m"
			}
			// Add expiry to some jobs.
			if i%10 == 0 {
				body["expire_after"] = "24h"
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

		// Unique key / idempotent jobs.
		for i := 0; i < 3; i++ {
			if err := postOK("/api/v1/enqueue", map[string]any{
				"queue":         "emails.send",
				"payload":       map[string]any{"type": "seed-unique", "recipient": "dedup@example.com"},
				"unique_key":    "email:dedup@example.com",
				"unique_period": 3600,
			}); err != nil {
				return err
			}
		}
		fmt.Println("- unique key dedup: 3 enqueued, should result in 1 job")

		// Chained job pipeline: ingest -> transform -> notify, with failure handler.
		var chainEnq enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   "pipeline.ingest",
			"payload": map[string]any{"type": "seed-chain", "source": "s3://data/batch-001.csv"},
			"chain": map[string]any{
				"steps": []map[string]any{
					{"queue": "pipeline.ingest", "payload": map[string]any{"source": "s3://data/batch-001.csv"}},
					{"queue": "pipeline.transform", "payload": map[string]any{"format": "parquet"}},
					{"queue": "pipeline.notify", "payload": map[string]any{"channel": "#data-team"}},
				},
				"on_failure": map[string]any{"queue": "pipeline.failure", "payload": map[string]any{"alert": true}},
				"on_exit":    map[string]any{"queue": "pipeline.cleanup"},
			},
			"tags": map[string]any{"pipeline": "etl-daily"},
		}, &chainEnq); err != nil {
			return err
		}
		// Complete the first step so the chain progresses.
		if chainEnq.JobID != "" {
			jobID, err := fetchOne("pipeline.ingest")
			if err != nil {
				return err
			}
			if jobID != "" {
				_ = postOK("/api/v1/ack/"+jobID, map[string]any{
					"result":      map[string]any{"rows_ingested": 15420},
					"step_status": "done",
				})
			}
		}

		// Job with dependencies: create parent jobs, then a child that depends on them.
		var dep1, dep2 enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   "reports.generate",
			"payload": map[string]any{"type": "seed-dep-parent", "report": "sales-q4"},
			"tags":    map[string]any{"dependency": "parent"},
		}, &dep1); err != nil {
			return err
		}
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   "reports.generate",
			"payload": map[string]any{"type": "seed-dep-parent", "report": "inventory-q4"},
			"tags":    map[string]any{"dependency": "parent"},
		}, &dep2); err != nil {
			return err
		}
		var depChild enqueueResult
		depIDs := []string{}
		if dep1.JobID != "" {
			depIDs = append(depIDs, dep1.JobID)
		}
		if dep2.JobID != "" {
			depIDs = append(depIDs, dep2.JobID)
		}
		if len(depIDs) > 0 {
			if err := postDecode("/api/v1/enqueue", map[string]any{
				"queue":      "reports.generate",
				"payload":    map[string]any{"type": "seed-dep-child", "report": "combined-q4-summary"},
				"depends_on": depIDs,
				"tags":       map[string]any{"dependency": "child"},
			}, &depChild); err != nil {
				return err
			}
		}

		// Approval policy + job that triggers it.
		_ = postOK("/api/v1/approval-policies", map[string]any{
			"name":     "high-value-review",
			"mode":     "any",
			"queue":    "emails.send",
			"tag_key":  "requires_approval",
			"tag_value": "true",
		})
		var approvalEnq enqueueResult
		if err := postDecode("/api/v1/enqueue", map[string]any{
			"queue":   "emails.send",
			"payload": map[string]any{"type": "seed-approval", "campaign": "black-friday-blast"},
			"tags":    map[string]any{"requires_approval": "true", "tenant": "tenant-1"},
		}, &approvalEnq); err != nil {
			return err
		}

		// Webhook (pointing to a non-existent URL, just for demo display).
		_ = postOK("/api/v1/webhooks", map[string]any{
			"url":         "https://hooks.example.com/corvo",
			"events":      []string{"job.completed", "job.failed", "job.dead"},
			"secret":      "whsec_demo_seed_secret",
			"enabled":     true,
			"retry_limit": 3,
		})

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
			if err := waitForJobVisible(agentEnq.JobID, 2*time.Second); err != nil {
				return err
			}
			if err := postOKWithRetry("/api/v1/scores", map[string]any{
				"job_id":    agentEnq.JobID,
				"dimension": "relevance",
				"value":     0.94,
				"scorer":    "auto:seed",
			}, 20, 100*time.Millisecond); err != nil {
				return err
			}
			if err := postOKWithRetry("/api/v1/scores", map[string]any{
				"job_id":    agentEnq.JobID,
				"dimension": "grounding",
				"value":     0.89,
				"scorer":    "auto:seed",
			}, 20, 100*time.Millisecond); err != nil {
				return err
			}
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
		if chainEnq.JobID != "" {
			fmt.Printf("- chain pipeline job: %s\n", chainEnq.JobID)
		}
		if depChild.JobID != "" {
			fmt.Printf("- dependency child job: %s (depends on %d parents)\n", depChild.JobID, len(depIDs))
		}
		if approvalEnq.JobID != "" {
			fmt.Printf("- approval-held job: %s\n", approvalEnq.JobID)
		}
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

func postOKWithRetry(path string, body any, attempts int, backoff time.Duration) error {
	if attempts <= 1 {
		return postOK(path, body)
	}
	var lastErr error
	for i := 0; i < attempts; i++ {
		if err := postOK(path, body); err == nil {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(backoff)
	}
	return lastErr
}

func waitForJobVisible(jobID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	path := "/api/v1/jobs/" + jobID
	for time.Now().Before(deadline) {
		data, status, err := apiRequest("GET", path, nil)
		if err == nil && status == 200 {
			return nil
		}
		if err == nil && status >= 500 {
			return fmt.Errorf("GET %s failed (%d): %s", path, status, string(data))
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("job %s not visible in time", jobID)
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
