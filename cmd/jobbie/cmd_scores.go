package main

import (
	"encoding/json"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var scoresCmd = &cobra.Command{
	Use:   "scores",
	Short: "Manage and inspect job scores",
}

var (
	scoresQueue   string
	scoresPeriod  string
	scoresGroupBy string
)

var scoresSummaryCmd = &cobra.Command{
	Use:   "summary",
	Short: "Show aggregate score summary",
	RunE: func(cmd *cobra.Command, args []string) error {
		path := "/api/v1/scores/summary"
		q := ""
		if scoresQueue != "" {
			q += "queue=" + scoresQueue
		}
		if scoresPeriod != "" {
			if q != "" {
				q += "&"
			}
			q += "period=" + scoresPeriod
		}
		if q != "" {
			path += "?" + q
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
		var out struct {
			Dimensions map[string]struct {
				Mean  float64 `json:"mean"`
				P50   float64 `json:"p50"`
				P5    float64 `json:"p5"`
				Count int64   `json:"count"`
			} `json:"dimensions"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return err
		}
		if len(out.Dimensions) == 0 {
			fmt.Println("No scores")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "DIMENSION\tMEAN\tP50\tP5\tCOUNT")
		for dim, s := range out.Dimensions {
			fmt.Fprintf(w, "%s\t%.4f\t%.4f\t%.4f\t%d\n", dim, s.Mean, s.P50, s.P5, s.Count)
		}
		w.Flush()
		return nil
	},
}

var scoresAddCmd = &cobra.Command{
	Use:   "add <job-id> <dimension> <value>",
	Short: "Add a score for a job",
	Args:  cobra.ExactArgs(3),
	RunE: func(cmd *cobra.Command, args []string) error {
		var value float64
		if _, err := fmt.Sscanf(args[2], "%f", &value); err != nil {
			return fmt.Errorf("invalid value: %w", err)
		}
		body := map[string]any{
			"job_id":    args[0],
			"dimension": args[1],
			"value":     value,
		}
		if scorer != "" {
			body["scorer"] = scorer
		}
		data, status, err := apiRequest("POST", "/api/v1/scores", body)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		fmt.Printf("Score added: %s %s=%.4f\n", args[0], args[1], value)
		return nil
	},
}

var scoresCompareCmd = &cobra.Command{
	Use:   "compare",
	Short: "Compare score dimensions across groups",
	RunE: func(cmd *cobra.Command, args []string) error {
		path := "/api/v1/scores/compare"
		q := ""
		if scoresQueue != "" {
			q += "queue=" + scoresQueue
		}
		if scoresPeriod != "" {
			if q != "" {
				q += "&"
			}
			q += "period=" + scoresPeriod
		}
		if scoresGroupBy != "" {
			if q != "" {
				q += "&"
			}
			q += "group_by=" + scoresGroupBy
		}
		if q != "" {
			path += "?" + q
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
		var out struct {
			Groups []struct {
				Key        string `json:"key"`
				Dimensions map[string]struct {
					Mean  float64 `json:"mean"`
					P50   float64 `json:"p50"`
					P5    float64 `json:"p5"`
					Count int64   `json:"count"`
				} `json:"dimensions"`
			} `json:"groups"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return err
		}
		if len(out.Groups) == 0 {
			fmt.Println("No scores")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "GROUP\tDIMENSION\tMEAN\tP50\tP5\tCOUNT")
		for _, g := range out.Groups {
			for dim, s := range g.Dimensions {
				fmt.Fprintf(w, "%s\t%s\t%.4f\t%.4f\t%.4f\t%d\n", g.Key, dim, s.Mean, s.P50, s.P5, s.Count)
			}
		}
		w.Flush()
		return nil
	},
}

var scorer string

var scoresJobCmd = &cobra.Command{
	Use:   "job <job-id>",
	Short: "List scores for a job",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		data, status, err := apiRequest("GET", "/api/v1/jobs/"+args[0]+"/scores", nil)
		if err != nil {
			return err
		}
		exitOnError(data, status)
		if outputJSON {
			printJSON(data)
			return nil
		}
		var out struct {
			Scores []struct {
				Dimension string  `json:"dimension"`
				Value     float64 `json:"value"`
				Scorer    *string `json:"scorer,omitempty"`
				CreatedAt string  `json:"created_at"`
			} `json:"scores"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return err
		}
		if len(out.Scores) == 0 {
			fmt.Println("No scores")
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "DIMENSION\tVALUE\tSCORER\tCREATED_AT")
		for _, s := range out.Scores {
			scorerVal := ""
			if s.Scorer != nil {
				scorerVal = *s.Scorer
			}
			fmt.Fprintf(w, "%s\t%.4f\t%s\t%s\n", s.Dimension, s.Value, scorerVal, s.CreatedAt)
		}
		w.Flush()
		return nil
	},
}

func init() {
	scoresSummaryCmd.Flags().StringVar(&scoresQueue, "queue", "", "Filter by queue")
	scoresSummaryCmd.Flags().StringVar(&scoresPeriod, "period", "24h", "Period (e.g. 24h, 7d)")
	scoresCompareCmd.Flags().StringVar(&scoresQueue, "queue", "", "Filter by queue")
	scoresCompareCmd.Flags().StringVar(&scoresPeriod, "period", "24h", "Period (e.g. 24h, 7d)")
	scoresCompareCmd.Flags().StringVar(&scoresGroupBy, "group-by", "queue", "Grouping key (queue or tag:<key>)")
	scoresAddCmd.Flags().StringVar(&scorer, "scorer", "", "Scorer identifier")

	scoresCmd.AddCommand(scoresJobCmd, scoresSummaryCmd, scoresCompareCmd, scoresAddCmd)
	addClientFlags(scoresCmd, scoresJobCmd, scoresSummaryCmd, scoresCompareCmd, scoresAddCmd)
	rootCmd.AddCommand(scoresCmd)
}
