package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

var (
	searchQueue           string
	searchState           string
	searchPriority        string
	searchPayloadContains string
	searchErrorContains   string
	searchTag             string
	searchCreatedAfter    string
	searchCreatedBefore   string
	searchLimit           int
	searchSort            string
	searchOrder           string
)

var searchCmd = &cobra.Command{
	Use:   "search",
	Short: "Search jobs with filters",
	RunE: func(cmd *cobra.Command, args []string) error {
		filter := map[string]interface{}{}
		if searchQueue != "" {
			filter["queue"] = searchQueue
		}
		if searchState != "" {
			filter["state"] = strings.Split(searchState, ",")
		}
		if searchPriority != "" {
			filter["priority"] = searchPriority
		}
		if searchPayloadContains != "" {
			filter["payload_contains"] = searchPayloadContains
		}
		if searchErrorContains != "" {
			filter["error_contains"] = searchErrorContains
		}
		if searchTag != "" {
			// Parse "key=value" format
			parts := strings.SplitN(searchTag, "=", 2)
			if len(parts) == 2 {
				filter["tags"] = map[string]string{parts[0]: parts[1]}
			}
		}
		if searchCreatedAfter != "" {
			filter["created_after"] = searchCreatedAfter
		}
		if searchCreatedBefore != "" {
			filter["created_before"] = searchCreatedBefore
		}
		if searchLimit > 0 {
			filter["limit"] = searchLimit
		}
		if searchSort != "" {
			filter["sort"] = searchSort
		}
		if searchOrder != "" {
			filter["order"] = searchOrder
		}

		data, status, err := apiRequest("POST", "/api/v1/jobs/search", filter)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			// For piping: output just job IDs, one per line
			var result struct {
				Jobs []struct {
					ID string `json:"id"`
				} `json:"jobs"`
			}
			json.Unmarshal(data, &result)
			for _, j := range result.Jobs {
				fmt.Println(j.ID)
			}
			return nil
		}

		printJSON(data)
		return nil
	},
}

var bulkAction string
var bulkFilter string

var bulkCmd = &cobra.Command{
	Use:   "bulk <action>",
	Short: "Apply bulk action (retry, delete, cancel, move, requeue)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		action := args[0]
		body := map[string]interface{}{
			"action": action,
		}

		if bulkFilter != "" {
			var filter map[string]interface{}
			if err := json.Unmarshal([]byte(bulkFilter), &filter); err != nil {
				return fmt.Errorf("invalid filter JSON: %w", err)
			}
			body["filter"] = filter
		} else {
			// Read job IDs from stdin
			var ids []string
			scanner := bufio.NewScanner(os.Stdin)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line != "" {
					ids = append(ids, line)
				}
			}
			if len(ids) == 0 {
				return fmt.Errorf("no job IDs provided (pipe from search or use --filter)")
			}
			body["job_ids"] = ids
		}

		data, status, err := apiRequest("POST", "/api/v1/jobs/bulk", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			printJSON(data)
		} else {
			var result map[string]interface{}
			json.Unmarshal(data, &result)
			fmt.Printf("Affected: %.0f jobs (%.0fms)\n", result["affected"], result["duration_ms"])
		}
		return nil
	},
}

func init() {
	searchCmd.Flags().StringVar(&searchQueue, "queue", "", "Filter by queue")
	searchCmd.Flags().StringVar(&searchState, "state", "", "Filter by state (comma-separated)")
	searchCmd.Flags().StringVar(&searchPriority, "priority", "", "Filter by priority")
	searchCmd.Flags().StringVar(&searchPayloadContains, "payload-contains", "", "Payload substring search")
	searchCmd.Flags().StringVar(&searchErrorContains, "error-contains", "", "Error substring search")
	searchCmd.Flags().StringVar(&searchTag, "tag", "", "Filter by tag (key=value)")
	searchCmd.Flags().StringVar(&searchCreatedAfter, "created-after", "", "Filter by created after (RFC3339)")
	searchCmd.Flags().StringVar(&searchCreatedBefore, "created-before", "", "Filter by created before (RFC3339)")
	searchCmd.Flags().IntVar(&searchLimit, "limit", 50, "Max results")
	searchCmd.Flags().StringVar(&searchSort, "sort", "", "Sort field")
	searchCmd.Flags().StringVar(&searchOrder, "order", "", "Sort order (asc/desc)")

	bulkCmd.Flags().StringVar(&bulkFilter, "filter", "", "Bulk filter as JSON")

	addClientFlags(searchCmd, bulkCmd)
	rootCmd.AddCommand(searchCmd, bulkCmd)
}
