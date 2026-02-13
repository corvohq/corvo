package main

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"
)

var cacheCmd = &cobra.Command{
	Use:   "cache",
	Short: "Inspect cache-related usage metrics",
}

var cacheStatsCmd = &cobra.Command{
	Use:   "stats",
	Short: "Show cache token usage and hit rate",
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/usage/summary?period=24h", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var out struct {
			Totals struct {
				CacheCreationTokens int64 `json:"cache_creation_tokens"`
				CacheReadTokens     int64 `json:"cache_read_tokens"`
			} `json:"totals"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return err
		}
		total := out.Totals.CacheCreationTokens + out.Totals.CacheReadTokens
		rate := 0.0
		if total > 0 {
			rate = float64(out.Totals.CacheReadTokens) / float64(total) * 100.0
		}
		fmt.Printf("Cache create tokens: %d\n", out.Totals.CacheCreationTokens)
		fmt.Printf("Cache read tokens:   %d\n", out.Totals.CacheReadTokens)
		fmt.Printf("Estimated hit rate:  %.1f%%\n", rate)
		return nil
	},
}

func init() {
	cacheCmd.AddCommand(cacheStatsCmd)
	addClientFlags(cacheCmd, cacheStatsCmd)
	rootCmd.AddCommand(cacheCmd)
}
