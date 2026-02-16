package server

import (
	"fmt"
	"math"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"time"

	raftcluster "github.com/user/corvo/internal/raft"
)

// raftHistogramProvider is optionally implemented by cluster backends that
// expose histogram data for Prometheus scraping.
type raftHistogramProvider interface {
	QueueTimeHistogram() raftcluster.PromSnapshot
	ApplyTimeHistogram() raftcluster.PromSnapshot
}

func (s *Server) handlePrometheusMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)

	// --- Throughput ---
	enq, completed, failed := s.throughput.Totals()
	fmt.Fprintln(w, "# HELP corvo_throughput_enqueued_total Jobs enqueued in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE corvo_throughput_enqueued_total counter")
	fmt.Fprintf(w, "corvo_throughput_enqueued_total %d\n", enq)
	fmt.Fprintln(w, "# HELP corvo_throughput_completed_total Jobs completed in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE corvo_throughput_completed_total counter")
	fmt.Fprintf(w, "corvo_throughput_completed_total %d\n", completed)
	fmt.Fprintln(w, "# HELP corvo_throughput_failed_total Jobs failed in the in-memory throughput window.")
	fmt.Fprintln(w, "# TYPE corvo_throughput_failed_total counter")
	fmt.Fprintf(w, "corvo_throughput_failed_total %d\n", failed)

	// --- Lifecycle Stream ---
	if s.rpcServer != nil {
		st := s.rpcServer.Stats()
		fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_open Currently open lifecycle streams.")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_open gauge")
		fmt.Fprintf(w, "corvo_lifecycle_streams_open %d\n", st.OpenStreams)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_max Configured max open streams.")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_max gauge")
		fmt.Fprintf(w, "corvo_lifecycle_streams_max %d\n", st.MaxOpenStreams)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_inflight Currently processing frames.")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_inflight gauge")
		fmt.Fprintf(w, "corvo_lifecycle_frames_inflight %d\n", st.InFlight)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_max_inflight Configured max in-flight frames.")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_max_inflight gauge")
		fmt.Fprintf(w, "corvo_lifecycle_frames_max_inflight %d\n", st.MaxInFlight)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_total Total frames processed.")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_total counter")
		fmt.Fprintf(w, "corvo_lifecycle_frames_total %d\n", st.FramesTotal)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_total Total streams opened (lifetime).")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_total counter")
		fmt.Fprintf(w, "corvo_lifecycle_streams_total %d\n", st.StreamsTotal)
		fmt.Fprintln(w, "# HELP corvo_lifecycle_overload_total Frames rejected (stream saturated).")
		fmt.Fprintln(w, "# TYPE corvo_lifecycle_overload_total counter")
		fmt.Fprintf(w, "corvo_lifecycle_overload_total %d\n", st.OverloadTotal)
	}

	// --- Cluster / Raft ---
	if s.cluster != nil {
		leader := 0
		if s.cluster.IsLeader() {
			leader = 1
		}
		fmt.Fprintln(w, "# HELP corvo_cluster_is_leader 1 when this node is leader, else 0.")
		fmt.Fprintln(w, "# TYPE corvo_cluster_is_leader gauge")
		fmt.Fprintf(w, "corvo_cluster_is_leader %d\n", leader)

		status := s.cluster.ClusterStatus()

		// SQLite mirror
		if mirror, ok := status["sqlite_mirror"].(map[string]any); ok {
			if lag, ok := mirror["lag"]; ok {
				fmt.Fprintln(w, "# HELP corvo_sqlite_mirror_lag_updates Pending SQLite mirror updates.")
				fmt.Fprintln(w, "# TYPE corvo_sqlite_mirror_lag_updates gauge")
				fmt.Fprintf(w, "corvo_sqlite_mirror_lag_updates %v\n", lag)
			}
			if dropped, ok := mirror["dropped"]; ok {
				fmt.Fprintln(w, "# HELP corvo_sqlite_mirror_dropped_total Dropped SQLite mirror updates due to backpressure.")
				fmt.Fprintln(w, "# TYPE corvo_sqlite_mirror_dropped_total counter")
				fmt.Fprintf(w, "corvo_sqlite_mirror_dropped_total %v\n", dropped)
			}
		}

		// Raft apply pipeline
		fmt.Fprintln(w, "# HELP corvo_raft_apply_pending Current apply queue depth.")
		fmt.Fprintln(w, "# TYPE corvo_raft_apply_pending gauge")
		fmt.Fprintf(w, "corvo_raft_apply_pending %v\n", status["apply_pending_now"])
		fmt.Fprintln(w, "# HELP corvo_raft_apply_max_pending Configured max pending.")
		fmt.Fprintln(w, "# TYPE corvo_raft_apply_max_pending gauge")
		fmt.Fprintf(w, "corvo_raft_apply_max_pending %v\n", status["apply_max_pending"])

		if v, ok := status["overload_total"]; ok {
			fmt.Fprintln(w, "# HELP corvo_raft_apply_overload_total Rejected: apply queue full.")
			fmt.Fprintln(w, "# TYPE corvo_raft_apply_overload_total counter")
			fmt.Fprintf(w, "corvo_raft_apply_overload_total %v\n", v)
		}
		if v, ok := status["fetch_overload_total"]; ok {
			fmt.Fprintln(w, "# HELP corvo_raft_fetch_overload_total Rejected: per-queue fetch sem full.")
			fmt.Fprintln(w, "# TYPE corvo_raft_fetch_overload_total counter")
			fmt.Fprintf(w, "corvo_raft_fetch_overload_total %v\n", v)
		}
		if v, ok := status["applied_total"]; ok {
			fmt.Fprintln(w, "# HELP corvo_raft_applied_total Total ops applied through Raft.")
			fmt.Fprintln(w, "# TYPE corvo_raft_applied_total counter")
			fmt.Fprintf(w, "corvo_raft_applied_total %v\n", v)
		}

		// Raft state (numeric: 0=follower, 1=candidate, 2=leader, 3=shutdown)
		stateStr, _ := status["state"].(string)
		stateVal := raftStateToInt(stateStr)
		fmt.Fprintln(w, "# HELP corvo_raft_state Raft state: 0=follower, 1=candidate, 2=leader, 3=shutdown.")
		fmt.Fprintln(w, "# TYPE corvo_raft_state gauge")
		fmt.Fprintf(w, "corvo_raft_state %d\n", stateVal)

		// Raft indices
		if v, ok := status["applied_index"]; ok {
			fmt.Fprintln(w, "# HELP corvo_raft_applied_index Last applied log index.")
			fmt.Fprintln(w, "# TYPE corvo_raft_applied_index gauge")
			fmt.Fprintf(w, "corvo_raft_applied_index %s\n", anyToString(v))
		}
		if v, ok := status["commit_index"]; ok {
			fmt.Fprintln(w, "# HELP corvo_raft_commit_index Last committed log index.")
			fmt.Fprintln(w, "# TYPE corvo_raft_commit_index gauge")
			fmt.Fprintf(w, "corvo_raft_commit_index %s\n", anyToString(v))
		}

		// Snapshot index
		if snap, ok := status["snapshot"].(map[string]any); ok {
			if idx, ok := snap["latest_index"]; ok {
				fmt.Fprintln(w, "# HELP corvo_raft_snapshot_latest_index Latest snapshot index.")
				fmt.Fprintln(w, "# TYPE corvo_raft_snapshot_latest_index gauge")
				fmt.Fprintf(w, "corvo_raft_snapshot_latest_index %v\n", idx)
			}
		}

		// Raft histograms
		if hp, ok := s.cluster.(raftHistogramProvider); ok {
			writePromHistogram(w, "corvo_raft_queue_time_seconds", "Wait time in apply queue.", hp.QueueTimeHistogram())
			writePromHistogram(w, "corvo_raft_apply_time_seconds", "FSM apply execution time.", hp.ApplyTimeHistogram())
		}
	}

	// --- Queue Jobs ---
	queues, err := s.store.ListQueues()
	if err != nil {
		fmt.Fprintln(w, "# HELP corvo_metrics_errors_total Errors while collecting metrics.")
		fmt.Fprintln(w, "# TYPE corvo_metrics_errors_total counter")
		fmt.Fprintln(w, "corvo_metrics_errors_total 1")
		return
	}

	fmt.Fprintln(w, "# HELP corvo_queues_total Number of known queues.")
	fmt.Fprintln(w, "# TYPE corvo_queues_total gauge")
	fmt.Fprintf(w, "corvo_queues_total %d\n", len(queues))

	totalByState := map[string]int{
		"pending":   0,
		"active":    0,
		"held":      0,
		"completed": 0,
		"dead":      0,
		"scheduled": 0,
		"retrying":  0,
	}
	fmt.Fprintln(w, "# HELP corvo_queue_jobs Jobs per queue and state.")
	fmt.Fprintln(w, "# TYPE corvo_queue_jobs gauge")
	for _, q := range queues {
		queue := promLabelEscape(q.Name)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"pending\"} %d\n", queue, q.Pending)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"active\"} %d\n", queue, q.Active)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"held\"} %d\n", queue, q.Held)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"completed\"} %d\n", queue, q.Completed)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"dead\"} %d\n", queue, q.Dead)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"scheduled\"} %d\n", queue, q.Scheduled)
		fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"retrying\"} %d\n", queue, q.Retrying)

		totalByState["pending"] += q.Pending
		totalByState["active"] += q.Active
		totalByState["held"] += q.Held
		totalByState["completed"] += q.Completed
		totalByState["dead"] += q.Dead
		totalByState["scheduled"] += q.Scheduled
		totalByState["retrying"] += q.Retrying
	}

	fmt.Fprintln(w, "# HELP corvo_jobs Jobs aggregated across all queues by state.")
	fmt.Fprintln(w, "# TYPE corvo_jobs gauge")
	for _, state := range []string{"pending", "active", "held", "completed", "dead", "scheduled", "retrying"} {
		fmt.Fprintf(w, "corvo_jobs{state=\"%s\"} %d\n", state, totalByState[state])
	}

	// --- Workers ---
	db := s.store.ReadDB()
	if db != nil {
		var registered, active int
		_ = db.QueryRow("SELECT COUNT(*) FROM workers").Scan(&registered)
		_ = db.QueryRow("SELECT COUNT(*) FROM workers WHERE last_heartbeat > ?",
			time.Now().Add(-5*time.Minute).Format("2006-01-02T15:04:05.000")).Scan(&active)
		fmt.Fprintln(w, "# HELP corvo_workers_registered Total registered workers.")
		fmt.Fprintln(w, "# TYPE corvo_workers_registered gauge")
		fmt.Fprintf(w, "corvo_workers_registered %d\n", registered)
		fmt.Fprintln(w, "# HELP corvo_workers_active Workers with heartbeat within last 5 minutes.")
		fmt.Fprintln(w, "# TYPE corvo_workers_active gauge")
		fmt.Fprintf(w, "corvo_workers_active %d\n", active)
	}

	// --- Process Resources ---
	fmt.Fprintln(w, "# HELP corvo_process_goroutines Number of goroutines.")
	fmt.Fprintln(w, "# TYPE corvo_process_goroutines gauge")
	fmt.Fprintf(w, "corvo_process_goroutines %d\n", runtime.NumGoroutine())

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	fmt.Fprintln(w, "# HELP corvo_process_heap_inuse_bytes Heap memory in use.")
	fmt.Fprintln(w, "# TYPE corvo_process_heap_inuse_bytes gauge")
	fmt.Fprintf(w, "corvo_process_heap_inuse_bytes %d\n", memStats.HeapInuse)
	fmt.Fprintln(w, "# HELP corvo_process_stack_inuse_bytes Stack memory in use.")
	fmt.Fprintln(w, "# TYPE corvo_process_stack_inuse_bytes gauge")
	fmt.Fprintf(w, "corvo_process_stack_inuse_bytes %d\n", memStats.StackInuse)
	fmt.Fprintln(w, "# HELP corvo_process_gc_pause_ns Last GC pause duration (ns).")
	fmt.Fprintln(w, "# TYPE corvo_process_gc_pause_ns gauge")
	lastPauseIdx := (memStats.NumGC + 255) % 256
	fmt.Fprintf(w, "corvo_process_gc_pause_ns %d\n", memStats.PauseNs[lastPauseIdx])

	// --- Scheduler ---
	if s.schedulerMetrics != nil {
		m := s.schedulerMetrics
		fmt.Fprintln(w, "# HELP corvo_scheduler_promote_total Promote ops executed.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_promote_total counter")
		fmt.Fprintf(w, "corvo_scheduler_promote_total %d\n", m.PromoteRuns.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_promote_errors_total Promote errors.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_promote_errors_total counter")
		fmt.Fprintf(w, "corvo_scheduler_promote_errors_total %d\n", m.PromoteErrors.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_reclaim_total Reclaim ops executed.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_reclaim_total counter")
		fmt.Fprintf(w, "corvo_scheduler_reclaim_total %d\n", m.ReclaimRuns.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_reclaim_errors_total Reclaim errors.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_reclaim_errors_total counter")
		fmt.Fprintf(w, "corvo_scheduler_reclaim_errors_total %d\n", m.ReclaimErrors.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_expire_total Expire ops executed.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_expire_total counter")
		fmt.Fprintf(w, "corvo_scheduler_expire_total %d\n", m.ExpireRuns.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_expire_errors_total Expire errors.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_expire_errors_total counter")
		fmt.Fprintf(w, "corvo_scheduler_expire_errors_total %d\n", m.ExpireErrors.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_purge_total Purge ops executed.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_purge_total counter")
		fmt.Fprintf(w, "corvo_scheduler_purge_total %d\n", m.PurgeRuns.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_purge_errors_total Purge errors.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_purge_errors_total counter")
		fmt.Fprintf(w, "corvo_scheduler_purge_errors_total %d\n", m.PurgeErrors.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_last_promote_seconds Unix timestamp of last promote.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_last_promote_seconds gauge")
		fmt.Fprintf(w, "corvo_scheduler_last_promote_seconds %d\n", m.LastPromote.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_last_reclaim_seconds Unix timestamp of last reclaim.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_last_reclaim_seconds gauge")
		fmt.Fprintf(w, "corvo_scheduler_last_reclaim_seconds %d\n", m.LastReclaim.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_last_expire_seconds Unix timestamp of last expire.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_last_expire_seconds gauge")
		fmt.Fprintf(w, "corvo_scheduler_last_expire_seconds %d\n", m.LastExpire.Load())
		fmt.Fprintln(w, "# HELP corvo_scheduler_last_purge_seconds Unix timestamp of last purge.")
		fmt.Fprintln(w, "# TYPE corvo_scheduler_last_purge_seconds gauge")
		fmt.Fprintf(w, "corvo_scheduler_last_purge_seconds %d\n", m.LastPurge.Load())
	}

	// --- Request Metrics ---
	if s.reqMetrics != nil {
		fmt.Fprint(w, s.reqMetrics.renderPrometheus())
	}
}

func writePromHistogram(w http.ResponseWriter, name, help string, snap raftcluster.PromSnapshot) {
	fmt.Fprintf(w, "# HELP %s %s\n", name, help)
	fmt.Fprintf(w, "# TYPE %s histogram\n", name)
	for _, b := range snap.Buckets {
		le := "+Inf"
		if !math.IsInf(b.Le, 1) {
			le = strconv.FormatFloat(b.Le, 'g', -1, 64)
		}
		fmt.Fprintf(w, "%s_bucket{le=\"%s\"} %d\n", name, le, b.Count)
	}
	fmt.Fprintf(w, "%s_sum %g\n", name, snap.Sum)
	fmt.Fprintf(w, "%s_count %d\n", name, snap.Count)
}

func raftStateToInt(state string) int {
	switch strings.ToLower(state) {
	case "follower":
		return 0
	case "candidate":
		return 1
	case "leader":
		return 2
	case "shutdown":
		return 3
	default:
		return 0
	}
}

func anyToString(v any) string {
	switch val := v.(type) {
	case string:
		return val
	case int:
		return strconv.Itoa(val)
	case int64:
		return strconv.FormatInt(val, 10)
	case uint64:
		return strconv.FormatUint(val, 10)
	case float64:
		return strconv.FormatFloat(val, 'f', -1, 64)
	default:
		return fmt.Sprintf("%v", v)
	}
}

func promLabelEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	return s
}
