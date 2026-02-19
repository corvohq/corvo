package server

import (
	"fmt"
	"math"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"time"

	raftcluster "github.com/corvohq/corvo/internal/raft"
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
	_, _ = fmt.Fprintln(w, "# HELP corvo_throughput_enqueued_total Jobs enqueued in the in-memory throughput window.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_throughput_enqueued_total counter")
	_, _ = fmt.Fprintf(w, "corvo_throughput_enqueued_total %d\n", enq)
	_, _ = fmt.Fprintln(w, "# HELP corvo_throughput_completed_total Jobs completed in the in-memory throughput window.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_throughput_completed_total counter")
	_, _ = fmt.Fprintf(w, "corvo_throughput_completed_total %d\n", completed)
	_, _ = fmt.Fprintln(w, "# HELP corvo_throughput_failed_total Jobs failed in the in-memory throughput window.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_throughput_failed_total counter")
	_, _ = fmt.Fprintf(w, "corvo_throughput_failed_total %d\n", failed)

	// --- Lifecycle Stream ---
	if s.rpcServer != nil {
		st := s.rpcServer.Stats()
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_open Currently open lifecycle streams.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_open gauge")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_streams_open %d\n", st.OpenStreams)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_max Configured max open streams.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_max gauge")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_streams_max %d\n", st.MaxOpenStreams)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_inflight Currently processing frames.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_inflight gauge")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_frames_inflight %d\n", st.InFlight)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_max_inflight Configured max in-flight frames.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_max_inflight gauge")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_frames_max_inflight %d\n", st.MaxInFlight)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_frames_total Total frames processed.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_frames_total counter")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_frames_total %d\n", st.FramesTotal)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_streams_total Total streams opened (lifetime).")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_streams_total counter")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_streams_total %d\n", st.StreamsTotal)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_overload_total Frames rejected (stream saturated).")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_overload_total counter")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_overload_total %d\n", st.OverloadTotal)
		_, _ = fmt.Fprintln(w, "# HELP corvo_lifecycle_idle_fetch_total Fetches that returned zero jobs (triggers 100ms server-side sleep).")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_lifecycle_idle_fetch_total counter")
		_, _ = fmt.Fprintf(w, "corvo_lifecycle_idle_fetch_total %d\n", st.IdleFetchTotal)
	}

	// --- Cluster / Raft ---
	if s.cluster != nil {
		leader := 0
		if s.cluster.IsLeader() {
			leader = 1
		}
		_, _ = fmt.Fprintln(w, "# HELP corvo_cluster_is_leader 1 when this node is leader, else 0.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_cluster_is_leader gauge")
		_, _ = fmt.Fprintf(w, "corvo_cluster_is_leader %d\n", leader)

		status := s.cluster.ClusterStatus()

		// SQLite mirror
		if mirror, ok := status["sqlite_mirror"].(map[string]any); ok {
			if lag, ok := mirror["lag"]; ok {
				_, _ = fmt.Fprintln(w, "# HELP corvo_sqlite_mirror_lag_updates Pending SQLite mirror updates.")
				_, _ = fmt.Fprintln(w, "# TYPE corvo_sqlite_mirror_lag_updates gauge")
				_, _ = fmt.Fprintf(w, "corvo_sqlite_mirror_lag_updates %v\n", lag)
			}
			if dropped, ok := mirror["dropped"]; ok {
				_, _ = fmt.Fprintln(w, "# HELP corvo_sqlite_mirror_dropped_total Dropped SQLite mirror updates due to backpressure.")
				_, _ = fmt.Fprintln(w, "# TYPE corvo_sqlite_mirror_dropped_total counter")
				_, _ = fmt.Fprintf(w, "corvo_sqlite_mirror_dropped_total %v\n", dropped)
			}
		}

		// Raft apply pipeline
		_, _ = fmt.Fprintln(w, "# HELP corvo_raft_apply_pending Current apply queue depth.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_apply_pending gauge")
		_, _ = fmt.Fprintf(w, "corvo_raft_apply_pending %v\n", status["apply_pending_now"])
		_, _ = fmt.Fprintln(w, "# HELP corvo_raft_apply_max_pending Configured max pending.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_apply_max_pending gauge")
		_, _ = fmt.Fprintf(w, "corvo_raft_apply_max_pending %v\n", status["apply_max_pending"])

		if v, ok := status["overload_total"]; ok {
			_, _ = fmt.Fprintln(w, "# HELP corvo_raft_apply_overload_total Rejected: apply queue full.")
			_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_apply_overload_total counter")
			_, _ = fmt.Fprintf(w, "corvo_raft_apply_overload_total %v\n", v)
		}
		if v, ok := status["fetch_overload_total"]; ok {
			_, _ = fmt.Fprintln(w, "# HELP corvo_raft_fetch_overload_total Rejected: per-queue fetch sem full.")
			_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_fetch_overload_total counter")
			_, _ = fmt.Fprintf(w, "corvo_raft_fetch_overload_total %v\n", v)
		}
		if v, ok := status["applied_total"]; ok {
			_, _ = fmt.Fprintln(w, "# HELP corvo_raft_applied_total Total ops applied through Raft.")
			_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_applied_total counter")
			_, _ = fmt.Fprintf(w, "corvo_raft_applied_total %v\n", v)
		}

		// Raft state (numeric: 0=follower, 1=candidate, 2=leader, 3=shutdown)
		stateStr, _ := status["state"].(string)
		stateVal := raftStateToInt(stateStr)
		_, _ = fmt.Fprintln(w, "# HELP corvo_raft_state Raft state: 0=follower, 1=candidate, 2=leader, 3=shutdown.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_state gauge")
		_, _ = fmt.Fprintf(w, "corvo_raft_state %d\n", stateVal)

		// Raft indices
		if v, ok := status["applied_index"]; ok {
			_, _ = fmt.Fprintln(w, "# HELP corvo_raft_applied_index Last applied log index.")
			_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_applied_index gauge")
			_, _ = fmt.Fprintf(w, "corvo_raft_applied_index %s\n", anyToString(v))
		}
		if v, ok := status["commit_index"]; ok {
			_, _ = fmt.Fprintln(w, "# HELP corvo_raft_commit_index Last committed log index.")
			_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_commit_index gauge")
			_, _ = fmt.Fprintf(w, "corvo_raft_commit_index %s\n", anyToString(v))
		}

		// Snapshot index
		if snap, ok := status["snapshot"].(map[string]any); ok {
			if idx, ok := snap["latest_index"]; ok {
				_, _ = fmt.Fprintln(w, "# HELP corvo_raft_snapshot_latest_index Latest snapshot index.")
				_, _ = fmt.Fprintln(w, "# TYPE corvo_raft_snapshot_latest_index gauge")
				_, _ = fmt.Fprintf(w, "corvo_raft_snapshot_latest_index %v\n", idx)
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
		_, _ = fmt.Fprintln(w, "# HELP corvo_metrics_errors_total Errors while collecting metrics.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_metrics_errors_total counter")
		_, _ = fmt.Fprintln(w, "corvo_metrics_errors_total 1")
		return
	}

	_, _ = fmt.Fprintln(w, "# HELP corvo_queues_total Number of known queues.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_queues_total gauge")
	_, _ = fmt.Fprintf(w, "corvo_queues_total %d\n", len(queues))

	totalByState := map[string]int{
		"pending":   0,
		"active":    0,
		"held":      0,
		"completed": 0,
		"dead":      0,
		"scheduled": 0,
		"retrying":  0,
	}
	_, _ = fmt.Fprintln(w, "# HELP corvo_queue_jobs Jobs per queue and state.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_queue_jobs gauge")
	for _, q := range queues {
		queue := promLabelEscape(q.Name)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"pending\"} %d\n", queue, q.Pending)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"active\"} %d\n", queue, q.Active)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"held\"} %d\n", queue, q.Held)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"completed\"} %d\n", queue, q.Completed)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"dead\"} %d\n", queue, q.Dead)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"scheduled\"} %d\n", queue, q.Scheduled)
		_, _ = fmt.Fprintf(w, "corvo_queue_jobs{queue=\"%s\",state=\"retrying\"} %d\n", queue, q.Retrying)

		totalByState["pending"] += q.Pending
		totalByState["active"] += q.Active
		totalByState["held"] += q.Held
		totalByState["completed"] += q.Completed
		totalByState["dead"] += q.Dead
		totalByState["scheduled"] += q.Scheduled
		totalByState["retrying"] += q.Retrying
	}

	_, _ = fmt.Fprintln(w, "# HELP corvo_jobs Jobs aggregated across all queues by state.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_jobs gauge")
	for _, state := range []string{"pending", "active", "held", "completed", "dead", "scheduled", "retrying"} {
		_, _ = fmt.Fprintf(w, "corvo_jobs{state=\"%s\"} %d\n", state, totalByState[state])
	}

	// --- Workers ---
	db := s.store.ReadDB()
	if db != nil {
		var registered, active int
		_ = db.QueryRow("SELECT COUNT(*) FROM workers").Scan(&registered)
		_ = db.QueryRow("SELECT COUNT(*) FROM workers WHERE last_heartbeat > ?",
			time.Now().Add(-5*time.Minute).Format("2006-01-02T15:04:05.000")).Scan(&active)
		_, _ = fmt.Fprintln(w, "# HELP corvo_workers_registered Total registered workers.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_workers_registered gauge")
		_, _ = fmt.Fprintf(w, "corvo_workers_registered %d\n", registered)
		_, _ = fmt.Fprintln(w, "# HELP corvo_workers_active Workers with heartbeat within last 5 minutes.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_workers_active gauge")
		_, _ = fmt.Fprintf(w, "corvo_workers_active %d\n", active)
	}

	// --- Process Resources ---
	_, _ = fmt.Fprintln(w, "# HELP corvo_process_goroutines Number of goroutines.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_process_goroutines gauge")
	_, _ = fmt.Fprintf(w, "corvo_process_goroutines %d\n", runtime.NumGoroutine())

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	_, _ = fmt.Fprintln(w, "# HELP corvo_process_heap_inuse_bytes Heap memory in use.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_process_heap_inuse_bytes gauge")
	_, _ = fmt.Fprintf(w, "corvo_process_heap_inuse_bytes %d\n", memStats.HeapInuse)
	_, _ = fmt.Fprintln(w, "# HELP corvo_process_stack_inuse_bytes Stack memory in use.")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_process_stack_inuse_bytes gauge")
	_, _ = fmt.Fprintf(w, "corvo_process_stack_inuse_bytes %d\n", memStats.StackInuse)
	_, _ = fmt.Fprintln(w, "# HELP corvo_process_gc_pause_ns Last GC pause duration (ns).")
	_, _ = fmt.Fprintln(w, "# TYPE corvo_process_gc_pause_ns gauge")
	lastPauseIdx := (memStats.NumGC + 255) % 256
	_, _ = fmt.Fprintf(w, "corvo_process_gc_pause_ns %d\n", memStats.PauseNs[lastPauseIdx])

	// --- Scheduler ---
	if s.schedulerMetrics != nil {
		m := s.schedulerMetrics
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_promote_total Promote ops executed.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_promote_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_promote_total %d\n", m.PromoteRuns.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_promote_errors_total Promote errors.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_promote_errors_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_promote_errors_total %d\n", m.PromoteErrors.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_reclaim_total Reclaim ops executed.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_reclaim_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_reclaim_total %d\n", m.ReclaimRuns.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_reclaim_errors_total Reclaim errors.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_reclaim_errors_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_reclaim_errors_total %d\n", m.ReclaimErrors.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_expire_total Expire ops executed.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_expire_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_expire_total %d\n", m.ExpireRuns.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_expire_errors_total Expire errors.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_expire_errors_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_expire_errors_total %d\n", m.ExpireErrors.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_purge_total Purge ops executed.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_purge_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_purge_total %d\n", m.PurgeRuns.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_purge_errors_total Purge errors.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_purge_errors_total counter")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_purge_errors_total %d\n", m.PurgeErrors.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_last_promote_seconds Unix timestamp of last promote.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_last_promote_seconds gauge")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_last_promote_seconds %d\n", m.LastPromote.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_last_reclaim_seconds Unix timestamp of last reclaim.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_last_reclaim_seconds gauge")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_last_reclaim_seconds %d\n", m.LastReclaim.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_last_expire_seconds Unix timestamp of last expire.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_last_expire_seconds gauge")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_last_expire_seconds %d\n", m.LastExpire.Load())
		_, _ = fmt.Fprintln(w, "# HELP corvo_scheduler_last_purge_seconds Unix timestamp of last purge.")
		_, _ = fmt.Fprintln(w, "# TYPE corvo_scheduler_last_purge_seconds gauge")
		_, _ = fmt.Fprintf(w, "corvo_scheduler_last_purge_seconds %d\n", m.LastPurge.Load())
	}

	// --- Request Metrics ---
	if s.reqMetrics != nil {
		_, _ = fmt.Fprint(w, s.reqMetrics.renderPrometheus())
	}
}

func writePromHistogram(w http.ResponseWriter, name, help string, snap raftcluster.PromSnapshot) {
	_, _ = fmt.Fprintf(w, "# HELP %s %s\n", name, help)
	_, _ = fmt.Fprintf(w, "# TYPE %s histogram\n", name)
	for _, b := range snap.Buckets {
		le := "+Inf"
		if !math.IsInf(b.Le, 1) {
			le = strconv.FormatFloat(b.Le, 'g', -1, 64)
		}
		_, _ = fmt.Fprintf(w, "%s_bucket{le=\"%s\"} %d\n", name, le, b.Count)
	}
	_, _ = fmt.Fprintf(w, "%s_sum %g\n", name, snap.Sum)
	_, _ = fmt.Fprintf(w, "%s_count %d\n", name, snap.Count)
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
