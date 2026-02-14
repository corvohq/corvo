package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var approvalPolicyCmd = &cobra.Command{
	Use:   "approval-policy",
	Short: "Manage approval policies for agent jobs",
}

var approvalPolicyListCmd = &cobra.Command{
	Use:   "list",
	Short: "List approval policies",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/approval-policies", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var out []struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			Mode     string `json:"mode"`
			Enabled  bool   `json:"enabled"`
			Queue    string `json:"queue,omitempty"`
			TagKey   string `json:"tag_key,omitempty"`
			TagValue string `json:"tag_value,omitempty"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return err
		}
		if len(out) == 0 {
			fmt.Println("No approval policies configured")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tNAME\tMODE\tENABLED\tQUEUE\tTAG")
		for _, p := range out {
			tag := ""
			if p.TagKey != "" {
				tag = p.TagKey + "=" + p.TagValue
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%t\t%s\t%s\n", p.ID, p.Name, p.Mode, p.Enabled, p.Queue, tag)
		}
		w.Flush()
		return nil
	},
}

var (
	approvalPolicyMode     string
	approvalPolicyQueue    string
	approvalPolicyTag      string
	approvalPolicyDisabled bool
)

var approvalPolicySetCmd = &cobra.Command{
	Use:   "set <name>",
	Short: "Create an approval policy",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		body := map[string]any{
			"name": args[0],
			"mode": approvalPolicyMode,
		}
		if approvalPolicyDisabled {
			enabled := false
			body["enabled"] = enabled
		}
		if strings.TrimSpace(approvalPolicyQueue) != "" {
			body["queue"] = strings.TrimSpace(approvalPolicyQueue)
		}
		if strings.TrimSpace(approvalPolicyTag) != "" {
			parts := strings.SplitN(strings.TrimSpace(approvalPolicyTag), "=", 2)
			if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
				return fmt.Errorf("tag must be key=value")
			}
			body["tag_key"] = strings.TrimSpace(parts[0])
			body["tag_value"] = strings.TrimSpace(parts[1])
		}
		data, status, err := apiRequest("POST", "/api/v1/approval-policies", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		fmt.Printf("approval policy set: %s\n", args[0])
		return nil
	},
}

var approvalPolicyDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete an approval policy",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("DELETE", "/api/v1/approval-policies/"+args[0], nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		fmt.Printf("approval policy deleted: %s\n", args[0])
		return nil
	},
}

func init() {
	approvalPolicySetCmd.Flags().StringVar(&approvalPolicyMode, "mode", "any", "Policy match mode (any|all)")
	approvalPolicySetCmd.Flags().StringVar(&approvalPolicyQueue, "queue", "", "Queue to match")
	approvalPolicySetCmd.Flags().StringVar(&approvalPolicyTag, "tag", "", "Required tag as key=value")
	approvalPolicySetCmd.Flags().BoolVar(&approvalPolicyDisabled, "disabled", false, "Create policy disabled")

	approvalPolicyCmd.AddCommand(approvalPolicyListCmd, approvalPolicySetCmd, approvalPolicyDeleteCmd)
	addClientFlags(approvalPolicyCmd, approvalPolicyListCmd, approvalPolicySetCmd, approvalPolicyDeleteCmd)
	rootCmd.AddCommand(approvalPolicyCmd)
}
