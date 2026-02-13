package main

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"
)

var (
	enqPriority              string
	enqUniqueKey             string
	enqMaxRetries            int
	enqSchedule              string
	enqTags                  string
	enqAgentMaxIterations    int
	enqAgentMaxCostUSD       float64
	enqAgentIterationTimeout string
	replayFromIteration      int
)

var enqueueCmd = &cobra.Command{
	Use:   "enqueue <queue> <payload>",
	Short: "Enqueue a job",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		queue := args[0]
		payload := json.RawMessage(args[1])

		body := map[string]interface{}{
			"queue":   queue,
			"payload": payload,
		}
		if enqPriority != "" {
			body["priority"] = enqPriority
		}
		if enqUniqueKey != "" {
			body["unique_key"] = enqUniqueKey
		}
		if enqMaxRetries >= 0 {
			body["max_retries"] = enqMaxRetries
		}
		if enqSchedule != "" {
			body["scheduled_at"] = enqSchedule
		}
		if enqTags != "" {
			body["tags"] = json.RawMessage(enqTags)
		}
		if enqAgentMaxIterations > 0 || enqAgentMaxCostUSD > 0 || enqAgentIterationTimeout != "" {
			agent := map[string]interface{}{}
			if enqAgentMaxIterations > 0 {
				agent["max_iterations"] = enqAgentMaxIterations
			}
			if enqAgentMaxCostUSD > 0 {
				agent["max_cost_usd"] = enqAgentMaxCostUSD
			}
			if enqAgentIterationTimeout != "" {
				agent["iteration_timeout"] = enqAgentIterationTimeout
			}
			body["agent"] = agent
		}

		data, status, err := apiRequest("POST", "/api/v1/enqueue", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			printJSON(data)
		} else {
			var result map[string]interface{}
			json.Unmarshal(data, &result)
			fmt.Printf("Job enqueued: %s (status: %s)\n", result["job_id"], result["status"])
		}
		return nil
	},
}

var inspectCmd = &cobra.Command{
	Use:   "inspect <job-id>",
	Short: "Show full job detail",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/jobs/"+args[0], nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		printJSON(data)
		return nil
	},
}

var retryCmd = &cobra.Command{
	Use:   "retry <job-id>",
	Short: "Retry a failed/dead job",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/retry", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Println("Job retried")
		return nil
	},
}

var cancelCmd = &cobra.Command{
	Use:   "cancel <job-id>",
	Short: "Cancel a pending/active job",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/cancel", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		var result map[string]string
		json.Unmarshal(data, &result)
		fmt.Printf("Job %s: %s\n", args[0], result["status"])
		return nil
	},
}

var holdCmd = &cobra.Command{
	Use:   "hold <job-id>",
	Short: "Move a job to held state for human review",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/hold", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Job %s held\n", args[0])
		return nil
	},
}

var approveCmd = &cobra.Command{
	Use:   "approve <job-id>",
	Short: "Approve a held job back to pending",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/approve", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Job %s approved\n", args[0])
		return nil
	},
}

var rejectCmd = &cobra.Command{
	Use:   "reject <job-id>",
	Short: "Reject a held job to dead state",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/reject", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Job %s rejected\n", args[0])
		return nil
	},
}

var replayCmd = &cobra.Command{
	Use:   "replay <job-id>",
	Short: "Replay an agent job from a specific iteration",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if replayFromIteration <= 0 {
			return fmt.Errorf("--from must be > 0")
		}
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/replay", map[string]int{
			"from": replayFromIteration,
		})
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var result map[string]interface{}
		json.Unmarshal(data, &result)
		fmt.Printf("Replay enqueued: %s (status: %s)\n", result["job_id"], result["status"])
		return nil
	},
}

var iterationsCmd = &cobra.Command{
	Use:   "iterations <job-id>",
	Short: "List iteration history for an agent job",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/jobs/"+args[0]+"/iterations", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var resp struct {
			Iterations []struct {
				Iteration  int     `json:"iteration"`
				Status     string  `json:"status"`
				CostUSD    float64 `json:"cost_usd"`
				HoldReason *string `json:"hold_reason,omitempty"`
			} `json:"iterations"`
		}
		if err := json.Unmarshal(data, &resp); err != nil {
			return err
		}
		if len(resp.Iterations) == 0 {
			fmt.Println("No iterations")
			return nil
		}
		for _, it := range resp.Iterations {
			if it.HoldReason != nil && *it.HoldReason != "" {
				fmt.Printf("%d  %s  cost=%.6f  hold=%s\n", it.Iteration, it.Status, it.CostUSD, *it.HoldReason)
				continue
			}
			fmt.Printf("%d  %s  cost=%.6f\n", it.Iteration, it.Status, it.CostUSD)
		}
		return nil
	},
}

var heldCmd = &cobra.Command{
	Use:   "held",
	Short: "List held jobs awaiting approval",
	RunE: func(cmd *cobra.Command, args []string) error {
		body := map[string]any{
			"state": []string{"held"},
			"limit": 100,
			"sort":  "created_at",
			"order": "desc",
		}
		data, status, err := apiRequest("POST", "/api/v1/jobs/search", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var result struct {
			Jobs []struct {
				ID    string `json:"id"`
				Queue string `json:"queue"`
				State string `json:"state"`
			} `json:"jobs"`
		}
		if err := json.Unmarshal(data, &result); err != nil {
			return err
		}
		if len(result.Jobs) == 0 {
			fmt.Println("No held jobs")
			return nil
		}
		for _, j := range result.Jobs {
			fmt.Printf("%s  %s  %s\n", j.ID, j.Queue, j.State)
		}
		return nil
	},
}

var moveCmd = &cobra.Command{
	Use:   "move <job-id> <target-queue>",
	Short: "Move a job to another queue",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/move", map[string]string{
			"queue": args[1],
		})
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Job moved to %s\n", args[1])
		return nil
	},
}

var deleteCmd = &cobra.Command{
	Use:   "delete <job-id>",
	Short: "Delete a job",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("DELETE", "/api/v1/jobs/"+args[0], nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Println("Job deleted")
		return nil
	},
}

func init() {
	enqueueCmd.Flags().StringVar(&enqPriority, "priority", "", "Job priority (critical, high, normal)")
	enqueueCmd.Flags().StringVar(&enqUniqueKey, "unique-key", "", "Unique job key")
	enqueueCmd.Flags().IntVar(&enqMaxRetries, "max-retries", -1, "Maximum retry attempts")
	enqueueCmd.Flags().StringVar(&enqSchedule, "scheduled-at", "", "Schedule job for later (RFC3339)")
	enqueueCmd.Flags().StringVar(&enqTags, "tags", "", "Job tags as JSON object")
	enqueueCmd.Flags().IntVar(&enqAgentMaxIterations, "agent-max-iterations", 0, "Agent max iterations (enables agent mode)")
	enqueueCmd.Flags().Float64Var(&enqAgentMaxCostUSD, "agent-max-cost-usd", 0, "Agent max total USD cost guardrail")
	enqueueCmd.Flags().StringVar(&enqAgentIterationTimeout, "agent-iteration-timeout", "", "Agent per-iteration timeout (e.g. 2m)")
	replayCmd.Flags().IntVar(&replayFromIteration, "from", 0, "Replay from this agent iteration (required)")

	addClientFlags(enqueueCmd, inspectCmd, retryCmd, cancelCmd, holdCmd, approveCmd, rejectCmd, replayCmd, iterationsCmd, heldCmd, moveCmd, deleteCmd)
	rootCmd.AddCommand(enqueueCmd, inspectCmd, retryCmd, cancelCmd, holdCmd, approveCmd, rejectCmd, replayCmd, iterationsCmd, heldCmd, moveCmd, deleteCmd)
}
