package main

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"
)

var (
	enqPriority   string
	enqUniqueKey  string
	enqMaxRetries int
	enqSchedule   string
	enqTags       string
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

	addClientFlags(enqueueCmd, inspectCmd, retryCmd, cancelCmd, moveCmd, deleteCmd)
	rootCmd.AddCommand(enqueueCmd, inspectCmd, retryCmd, cancelCmd, moveCmd, deleteCmd)
}
