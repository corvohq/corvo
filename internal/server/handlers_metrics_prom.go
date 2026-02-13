package server

import (
	"fmt"
	"net/http"
	"strings"
)

func (s *Server) handlePrometheusMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)

	enq, completed, failed := s.throughput.Totals()
	fmt.Fprintln(w, "# HELP jobbie_throughput_enqueued_total Jobs enqueued in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE jobbie_throughput_enqueued_total counter")
	fmt.Fprintf(w, "jobbie_throughput_enqueued_total %d\n", enq)
	fmt.Fprintln(w, "# HELP jobbie_throughput_completed_total Jobs completed in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE jobbie_throughput_completed_total counter")
	fmt.Fprintf(w, "jobbie_throughput_completed_total %d\n", completed)
	fmt.Fprintln(w, "# HELP jobbie_throughput_failed_total Jobs failed in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE jobbie_throughput_failed_total counter")
	fmt.Fprintf(w, "jobbie_throughput_failed_total %d\n", failed)

	if s.cluster != nil {
		leader := 0
		if s.cluster.IsLeader() {
			leader = 1
		}
		fmt.Fprintln(w, "# HELP jobbie_cluster_is_leader 1 when this node is leader, else 0.")
		fmt.Fprintln(w, "# TYPE jobbie_cluster_is_leader gauge")
		fmt.Fprintf(w, "jobbie_cluster_is_leader %d\n", leader)
	}

	queues, err := s.store.ListQueues()
	if err != nil {
		fmt.Fprintln(w, "# HELP jobbie_metrics_errors_total Errors while collecting metrics.")
		fmt.Fprintln(w, "# TYPE jobbie_metrics_errors_total counter")
		fmt.Fprintln(w, "jobbie_metrics_errors_total 1")
		return
	}

	fmt.Fprintln(w, "# HELP jobbie_queues_total Number of known queues.")
	fmt.Fprintln(w, "# TYPE jobbie_queues_total gauge")
	fmt.Fprintf(w, "jobbie_queues_total %d\n", len(queues))

	totalByState := map[string]int{
		"pending":   0,
		"active":    0,
		"held":      0,
		"completed": 0,
		"dead":      0,
		"scheduled": 0,
		"retrying":  0,
	}
	fmt.Fprintln(w, "# HELP jobbie_queue_jobs Jobs per queue and state.")
	fmt.Fprintln(w, "# TYPE jobbie_queue_jobs gauge")
	for _, q := range queues {
		queue := promLabelEscape(q.Name)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"pending\"} %d\n", queue, q.Pending)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"active\"} %d\n", queue, q.Active)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"held\"} %d\n", queue, q.Held)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"completed\"} %d\n", queue, q.Completed)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"dead\"} %d\n", queue, q.Dead)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"scheduled\"} %d\n", queue, q.Scheduled)
		fmt.Fprintf(w, "jobbie_queue_jobs{queue=\"%s\",state=\"retrying\"} %d\n", queue, q.Retrying)

		totalByState["pending"] += q.Pending
		totalByState["active"] += q.Active
		totalByState["held"] += q.Held
		totalByState["completed"] += q.Completed
		totalByState["dead"] += q.Dead
		totalByState["scheduled"] += q.Scheduled
		totalByState["retrying"] += q.Retrying
	}

	fmt.Fprintln(w, "# HELP jobbie_jobs Jobs aggregated across all queues by state.")
	fmt.Fprintln(w, "# TYPE jobbie_jobs gauge")
	for _, state := range []string{"pending", "active", "held", "completed", "dead", "scheduled", "retrying"} {
		fmt.Fprintf(w, "jobbie_jobs{state=\"%s\"} %d\n", state, totalByState[state])
	}
}

func promLabelEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return s
}
