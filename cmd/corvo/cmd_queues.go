package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var queuesCmd = &cobra.Command{
	Use:   "queues",
	Short: "List all queues with stats",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/queues", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			printJSON(data)
			return nil
		}

		var queues []map[string]interface{}
		json.Unmarshal(data, &queues)

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "QUEUE\tPENDING\tACTIVE\tHELD\tCOMPLETED\tDEAD\tPAUSED")
		for _, q := range queues {
			paused := ""
			if p, ok := q["paused"].(bool); ok && p {
				paused = "yes"
			}
			fmt.Fprintf(w, "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n",
				q["name"],
				q["pending"], q["active"], q["held"], q["completed"], q["dead"],
				paused,
			)
		}
		w.Flush()
		return nil
	},
}

var pauseCmd = &cobra.Command{
	Use:   "pause <queue>",
	Short: "Pause a queue",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/queues/"+args[0]+"/pause", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s paused\n", args[0])
		return nil
	},
}

var resumeCmd = &cobra.Command{
	Use:   "resume <queue>",
	Short: "Resume a paused queue",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/queues/"+args[0]+"/resume", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s resumed\n", args[0])
		return nil
	},
}

var clearCmd = &cobra.Command{
	Use:   "clear <queue>",
	Short: "Clear all pending/scheduled jobs in a queue",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/queues/"+args[0]+"/clear", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s cleared\n", args[0])
		return nil
	},
}

var drainCmd = &cobra.Command{
	Use:   "drain <queue>",
	Short: "Drain a queue (pause + wait for active jobs)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/queues/"+args[0]+"/drain", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s draining\n", args[0])
		return nil
	},
}

var destroyConfirm bool

var destroyCmd = &cobra.Command{
	Use:   "destroy <queue>",
	Short: "Delete a queue and all its jobs",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if !destroyConfirm {
			return fmt.Errorf("use --confirm to delete queue %s and all its jobs", args[0])
		}
		data, status, err := apiRequest("DELETE", "/api/v1/queues/"+args[0], nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s destroyed\n", args[0])
		return nil
	},
}

func init() {
	destroyCmd.Flags().BoolVar(&destroyConfirm, "confirm", false, "Confirm queue destruction")

	addClientFlags(queuesCmd, pauseCmd, resumeCmd, clearCmd, drainCmd, destroyCmd)
	rootCmd.AddCommand(queuesCmd, pauseCmd, resumeCmd, clearCmd, drainCmd, destroyCmd)
}
