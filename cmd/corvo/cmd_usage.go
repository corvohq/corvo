package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/spf13/cobra"
)

var (
	usagePeriod  string
	usageGroupBy string
)

var usageCmd = &cobra.Command{
	Use:   "usage",
	Short: "Show usage/cost summary from worker-reported telemetry",
	RunE: func(cmd *cobra.Command, args []string) error {
		v := url.Values{}
		if strings.TrimSpace(usagePeriod) != "" {
			v.Set("period", strings.TrimSpace(usagePeriod))
		}
		if strings.TrimSpace(usageGroupBy) != "" {
			v.Set("group_by", strings.TrimSpace(usageGroupBy))
		}

		path := "/api/v1/usage/summary"
		if enc := v.Encode(); enc != "" {
			path += "?" + enc
		}

		data, status, err := apiRequest("GET", path, nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)

		if outputJSON {
			printJSON(data)
			return nil
		}

		var resp struct {
			Period string `json:"period"`
			From   string `json:"from"`
			To     string `json:"to"`
			Totals struct {
				InputTokens         int64   `json:"input_tokens"`
				OutputTokens        int64   `json:"output_tokens"`
				CacheCreationTokens int64   `json:"cache_creation_tokens"`
				CacheReadTokens     int64   `json:"cache_read_tokens"`
				CostUSD             float64 `json:"cost_usd"`
				Count               int64   `json:"count"`
			} `json:"totals"`
			Groups []struct {
				Key                 string  `json:"key"`
				InputTokens         int64   `json:"input_tokens"`
				OutputTokens        int64   `json:"output_tokens"`
				CacheCreationTokens int64   `json:"cache_creation_tokens"`
				CacheReadTokens     int64   `json:"cache_read_tokens"`
				CostUSD             float64 `json:"cost_usd"`
				Count               int64   `json:"count"`
			} `json:"groups"`
		}
		if err := json.Unmarshal(data, &resp); err != nil {
			return err
		}

		fmt.Printf("Usage summary (%s)\n", resp.Period)
		fmt.Printf("Window: %s -> %s\n", resp.From, resp.To)
		fmt.Printf("Total rows: %d\n", resp.Totals.Count)
		fmt.Printf("Input tokens: %d\n", resp.Totals.InputTokens)
		fmt.Printf("Output tokens: %d\n", resp.Totals.OutputTokens)
		fmt.Printf("Cache create tokens: %d\n", resp.Totals.CacheCreationTokens)
		fmt.Printf("Cache read tokens: %d\n", resp.Totals.CacheReadTokens)
		fmt.Printf("Total cost USD: %.6f\n", resp.Totals.CostUSD)
		if len(resp.Groups) > 0 {
			fmt.Println("Groups:")
			for _, g := range resp.Groups {
				fmt.Printf("- %s rows=%d in=%d out=%d cache_create=%d cache_read=%d cost=%.6f\n",
					g.Key, g.Count, g.InputTokens, g.OutputTokens, g.CacheCreationTokens, g.CacheReadTokens, g.CostUSD)
			}
		}
		return nil
	},
}

func init() {
	usageCmd.Flags().StringVar(&usagePeriod, "period", "24h", "Summary window duration (e.g. 1h, 24h, 168h)")
	usageCmd.Flags().StringVar(&usageGroupBy, "group-by", "", "Group by dimension: queue, model, provider")
	addClientFlags(usageCmd)
	rootCmd.AddCommand(usageCmd)
}
