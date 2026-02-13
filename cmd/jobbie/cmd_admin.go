package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show server status and queue summary",
	RunE: func(cmd *cobra.Command, args []string) error {
		clusterData, status, err := apiRequest("GET", "/api/v1/cluster/status", nil)
		if err != nil {
			return err
		}
		exitOnError(clusterData, status)

		queueData, status, err := apiRequest("GET", "/api/v1/queues", nil)
		if err != nil {
			return err
		}
		exitOnError(queueData, status)

		if outputJSON {
			result := map[string]json.RawMessage{
				"cluster": clusterData,
				"queues":  queueData,
			}
			b, _ := json.MarshalIndent(result, "", "  ")
			fmt.Println(string(b))
			return nil
		}

		var cluster map[string]interface{}
		json.Unmarshal(clusterData, &cluster)
		fmt.Printf("Mode: %s  Status: %s\n\n", cluster["mode"], cluster["status"])

		var queues []map[string]interface{}
		json.Unmarshal(queueData, &queues)

		if len(queues) == 0 {
			fmt.Println("No queues")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "QUEUE\tPENDING\tACTIVE\tHELD\tCOMPLETED\tDEAD")
		for _, q := range queues {
			fmt.Fprintf(w, "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",
				q["name"], q["pending"], q["active"], q["held"], q["completed"], q["dead"])
		}
		w.Flush()
		return nil
	},
}

var workersCmd = &cobra.Command{
	Use:   "workers",
	Short: "List connected workers",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/workers", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			printJSON(data)
			return nil
		}

		var workers []map[string]interface{}
		json.Unmarshal(data, &workers)

		if len(workers) == 0 {
			fmt.Println("No workers connected")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tHOSTNAME\tLAST HEARTBEAT")
		for _, worker := range workers {
			hostname := ""
			if h, ok := worker["hostname"].(string); ok {
				hostname = h
			}
			fmt.Fprintf(w, "%s\t%s\t%s\n",
				worker["id"], hostname, worker["last_heartbeat"])
		}
		w.Flush()
		return nil
	},
}

func init() {
	addClientFlags(statusCmd, workersCmd)
	rootCmd.AddCommand(statusCmd, workersCmd)
}
