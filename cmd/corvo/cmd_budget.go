package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var budgetCmd = &cobra.Command{
	Use:   "budget",
	Short: "Manage AI usage budgets",
}

var budgetListCmd = &cobra.Command{
	Use:   "list",
	Short: "List configured budgets",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/budgets", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var rows []map[string]any
		if err := json.Unmarshal(data, &rows); err != nil {
			return err
		}
		if len(rows) == 0 {
			fmt.Println("No budgets configured")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		_, _ = fmt.Fprintln(w, "SCOPE\tTARGET\tDAILY_USD\tPER_JOB_USD\tON_EXCEED")
		for _, r := range rows {
			_, _ = fmt.Fprintf(w, "%v\t%v\t%v\t%v\t%v\n",
				r["scope"], r["target"], r["daily_usd"], r["per_job_usd"], r["on_exceed"])
		}
		_ = w.Flush()
		return nil
	},
}

var (
	budgetDaily    float64
	budgetPerJob   float64
	budgetOnExceed string
)

var budgetSetCmd = &cobra.Command{
	Use:   "set <scope> <target>",
	Short: "Create or update a budget",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		var daily any
		var perJob any
		if cmd.Flags().Changed("daily") {
			daily = budgetDaily
		}
		if cmd.Flags().Changed("per-job") {
			perJob = budgetPerJob
		}
		body := map[string]any{
			"scope":       args[0],
			"target":      args[1],
			"daily_usd":   daily,
			"per_job_usd": perJob,
			"on_exceed":   budgetOnExceed,
		}
		data, status, err := apiRequest("POST", "/api/v1/budgets", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		fmt.Printf("Budget set for %s:%s\n", args[0], args[1])
		return nil
	},
}

var budgetDeleteCmd = &cobra.Command{
	Use:   "delete <scope> <target>",
	Short: "Delete a budget",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		path := fmt.Sprintf("/api/v1/budgets/%s/%s", args[0], args[1])
		data, status, err := apiRequest("DELETE", path, nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Budget deleted for %s:%s\n", args[0], args[1])
		return nil
	},
}

func init() {
	budgetSetCmd.Flags().Float64Var(&budgetDaily, "daily", 0, "Daily USD budget")
	budgetSetCmd.Flags().Float64Var(&budgetPerJob, "per-job", 0, "Per-job USD budget")
	budgetSetCmd.Flags().StringVar(&budgetOnExceed, "on-exceed", "hold", "Action on exceed: hold, reject, alert_only")

	budgetCmd.AddCommand(budgetListCmd, budgetSetCmd, budgetDeleteCmd)
	addClientFlags(budgetCmd, budgetListCmd, budgetSetCmd, budgetDeleteCmd)
	rootCmd.AddCommand(budgetCmd)
}
