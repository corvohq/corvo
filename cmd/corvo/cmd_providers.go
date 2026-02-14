package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var providersCmd = &cobra.Command{
	Use:   "providers",
	Short: "Manage LLM providers",
}

var providersListCmd = &cobra.Command{
	Use:   "list",
	Short: "List providers",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/providers", nil)
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
			fmt.Println("No providers configured")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tRPM\tINPUT_TPM\tOUTPUT_TPM")
		for _, r := range rows {
			fmt.Fprintf(w, "%v\t%v\t%v\t%v\n", r["name"], r["rpm_limit"], r["input_tpm_limit"], r["output_tpm_limit"])
		}
		w.Flush()
		return nil
	},
}

var (
	providerRPM       int
	providerInputTPM  int
	providerOutputTPM int
)

var providersSetCmd = &cobra.Command{
	Use:   "set <name>",
	Short: "Create or update a provider",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		body := map[string]any{"name": args[0]}
		if cmd.Flags().Changed("rpm") {
			body["rpm_limit"] = providerRPM
		}
		if cmd.Flags().Changed("input-tpm") {
			body["input_tpm_limit"] = providerInputTPM
		}
		if cmd.Flags().Changed("output-tpm") {
			body["output_tpm_limit"] = providerOutputTPM
		}
		data, status, err := apiRequest("POST", "/api/v1/providers", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		fmt.Printf("Provider set: %s\n", args[0])
		return nil
	},
}

var providersDeleteCmd = &cobra.Command{
	Use:   "delete <name>",
	Short: "Delete provider",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("DELETE", "/api/v1/providers/"+args[0], nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Provider deleted: %s\n", args[0])
		return nil
	},
}

var providersLinkCmd = &cobra.Command{
	Use:   "link-queue <queue> <provider>",
	Short: "Link a queue to a provider",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("POST", "/api/v1/queues/"+args[0]+"/provider", map[string]any{"provider": args[1]})
		if err != nil {
			return err
		}
		exitOnError(data, status)
		fmt.Printf("Queue %s linked to provider %s\n", args[0], args[1])
		return nil
	},
}

func init() {
	providersSetCmd.Flags().IntVar(&providerRPM, "rpm", 0, "Requests per minute limit")
	providersSetCmd.Flags().IntVar(&providerInputTPM, "input-tpm", 0, "Input tokens per minute limit")
	providersSetCmd.Flags().IntVar(&providerOutputTPM, "output-tpm", 0, "Output tokens per minute limit")

	providersCmd.AddCommand(providersListCmd, providersSetCmd, providersDeleteCmd, providersLinkCmd)
	addClientFlags(providersCmd, providersListCmd, providersSetCmd, providersDeleteCmd, providersLinkCmd)
	rootCmd.AddCommand(providersCmd)
}
