package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/spf13/cobra"
	"github.com/user/corvo/sdk/go/client"
	"github.com/user/corvo/sdk/go/worker"
)

const benchStreamsPerRPCClient = 200

// ── flag variables ──────────────────────────────────────────────────────────

var (
	benchServer         string
	benchAPIKey         string
	benchProtocol       string
	benchJobs           int
	benchConcurrency    int
	benchWorkers        int
	benchWorkerQueues   bool
	benchRepeats        int
	benchRepeatPause    time.Duration
	benchQueue          string
	benchEnqBatchSize   int
	benchFetchBatchSize int
	benchAckBatchSize   int
	benchWorkDuration   time.Duration
	benchPreset         string
	benchScenario       string
	benchCompare        string
	benchSave           string
	benchCombined       bool
	benchDockerCtrs     []string
	benchDockerNetwork  string
	benchFaultDuration  time.Duration
	benchFaultWarmup    time.Duration
)

// ── types ───────────────────────────────────────────────────────────────────

type benchResult struct {
	lats       []time.Duration
	serverLats []time.Duration
	elapsed    time.Duration
}

type benchRunSummary struct {
	opsPerSec   float64
	avg         time.Duration
	p50         time.Duration
	p90         time.Duration
	p99         time.Duration
	min         time.Duration
	max         time.Duration
	stddev      time.Duration
	cvPct       float64
	serverCvPct float64
	completed   int
}

type benchMachineInfo struct {
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	CPUs     int    `json:"cpus"`
	MemoryGB int    `json:"memory_gb"`
	Hostname string `json:"hostname"`
}

type benchServerConfig struct {
	Mode      string `json:"mode"`
	Nodes     int    `json:"nodes"`
	Shards    int    `json:"shards,omitempty"`
	RaftStore string `json:"raft_store,omitempty"`
	Durable   bool   `json:"durable"`
}

type benchPhaseResult struct {
	OpsPerSec     float64 `json:"ops_per_sec"`
	P50Us         int64   `json:"p50_us"`
	P90Us         int64   `json:"p90_us"`
	P99Us         int64   `json:"p99_us"`
	MinUs         int64   `json:"min_us"`
	MaxUs         int64   `json:"max_us"`
	StddevUs      int64   `json:"stddev_us"`
	CvPct         float64 `json:"cv_pct"`
	ServerCvPct   float64 `json:"server_cv_pct,omitempty"`
	Completed     int     `json:"completed"`
	ServerCPUPct  float64 `json:"server_cpu_pct,omitempty"`
	ServerRSSMB   float64 `json:"server_rss_mb,omitempty"`
	ServerGcP99Us int64   `json:"server_gc_p99_us,omitempty"`
}

type benchFaultResult struct {
	InjectedAt        string `json:"injected_at,omitempty"`
	RecoveredAt       string `json:"recovered_at,omitempty"`
	RecoveryMs        int64  `json:"recovery_ms,omitempty"`
	ErrorsDuringFault int    `json:"errors_during_fault,omitempty"`
}

type benchSaveData struct {
	Timestamp string             `json:"timestamp"`
	Commit    string             `json:"commit"`
	Machine   benchMachineInfo   `json:"machine"`
	Server    *benchServerConfig `json:"server,omitempty"`
	Preset    string             `json:"preset"`
	Scenario  string             `json:"scenario"`
	Config    map[string]any     `json:"config"`
	Enqueue   *benchPhaseResult  `json:"enqueue,omitempty"`
	Lifecycle *benchPhaseResult  `json:"lifecycle,omitempty"`
	Combined  *benchPhaseResult  `json:"combined,omitempty"`
	Fault     *benchFaultResult  `json:"fault,omitempty"`
}

type benchServerStats struct {
	Goroutines   int   `json:"goroutines"`
	GoMaxProcs   int   `json:"gomaxprocs"`
	HeapInuse    int64 `json:"heap_inuse_bytes"`
	StackInuse   int64 `json:"stack_inuse_bytes"`
	GCPauseP99Ns int64 `json:"gc_pause_p99_ns"`
	CPUUserNs    int64 `json:"cpu_user_ns"`
	CPUSysNs     int64 `json:"cpu_sys_ns"`
}

type benchFetchedItem struct {
	jobID   string
	started time.Time
}

// ── cobra command ───────────────────────────────────────────────────────────

var benchCmd = &cobra.Command{
	Use:   "bench",
	Short: "Run benchmarks against a Corvo server",
	Long: `Run enqueue and lifecycle processing benchmarks with optional presets,
docker-based fault injection scenarios, and run-to-run comparison.

By default, runs enqueue and lifecycle (fetch+ack) as separate phases.
Use --combined to run them concurrently, measuring end-to-end throughput
where producers enqueue while workers fetch and ack simultaneously.

Presets (--preset):
  single-node   10k jobs, 10 concurrency, 1 worker
  cluster        50k jobs, 50 concurrency, 5 workers, worker-queues
  failure        10k jobs, 20 concurrency, 3 workers, 5ms work-duration

Fault scenarios (--scenario, requires --preset failure):
  leader-kill    Kill the leader container
  partition      Disconnect a node from the docker network
  disk-full      Fill /tmp on a container
  worker-crash   Kill a worker container
  slow-node      Add 200ms latency via tc netem`,
	SilenceUsage: true,
	PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
		if cmd.Parent() != nil && cmd.Parent().PersistentPreRun != nil {
			cmd.Parent().PersistentPreRun(cmd, args)
		}
		return benchApplyPreset(cmd)
	},
	RunE: runBench,
}

func init() {
	f := benchCmd.Flags()
	f.StringVar(&benchServer, "server", "http://localhost:8080", "Corvo server URL")
	f.StringVar(&benchAPIKey, "api-key", "", "API key for authentication (env: CORVO_API_KEY)")
	f.StringVar(&benchProtocol, "protocol", "rpc", "Transport: rpc, http, or matrix")
	f.IntVar(&benchJobs, "jobs", 10000, "Total number of jobs")
	f.IntVar(&benchConcurrency, "concurrency", 10, "Concurrent goroutines")
	f.IntVar(&benchWorkers, "workers", 1, "Logical workers for lifecycle benchmark")
	f.BoolVar(&benchWorkerQueues, "worker-queues", false, "Use a distinct queue per worker")
	f.IntVar(&benchRepeats, "repeats", 1, "Benchmark repeats per protocol")
	f.DurationVar(&benchRepeatPause, "repeat-pause", 0, "Pause between repeats")
	f.StringVar(&benchQueue, "queue", "bench.q", "Queue name")
	f.IntVar(&benchEnqBatchSize, "enqueue-batch-size", 64, "Jobs per enqueue stream frame")
	f.IntVar(&benchFetchBatchSize, "fetch-batch-size", 64, "Jobs per fetch request")
	f.IntVar(&benchAckBatchSize, "ack-batch-size", 64, "ACKs per batch")
	f.DurationVar(&benchWorkDuration, "work-duration", 0, "Simulated per-job work duration")
	f.BoolVar(&benchCombined, "combined", false, "Run combined enqueue+fetch+ack benchmark (producers and workers run concurrently)")

	f.StringVar(&benchPreset, "preset", "", "Preset: single-node, cluster, or failure")
	f.StringVar(&benchScenario, "scenario", "", "Fault scenario (requires --preset failure)")
	f.StringVar(&benchCompare, "compare", "", "Baseline JSON file to compare against")
	f.StringVar(&benchSave, "save", "", "Save results to this path (default: bench-<timestamp>.json)")
	f.StringSliceVar(&benchDockerCtrs, "docker-container", nil, "Docker container name(s) for fault targets")
	f.StringVar(&benchDockerNetwork, "docker-network", "", "Docker network for partition scenario")
	f.DurationVar(&benchFaultDuration, "fault-duration", 10*time.Second, "Fault persistence duration")
	f.DurationVar(&benchFaultWarmup, "fault-warmup", 3*time.Second, "Workload warmup before fault injection")

	rootCmd.AddCommand(benchCmd)
}

// ── preset logic ────────────────────────────────────────────────────────────

func benchApplyPreset(cmd *cobra.Command) error {
	if benchPreset == "" {
		return nil
	}

	set := func(name string, val any) {
		if cmd.Flags().Changed(name) {
			return
		}
		switch v := val.(type) {
		case int:
			cmd.Flags().Set(name, strconv.Itoa(v))
		case bool:
			cmd.Flags().Set(name, strconv.FormatBool(v))
		case time.Duration:
			cmd.Flags().Set(name, v.String())
		}
	}

	switch benchPreset {
	case "single-node":
		set("jobs", 10000)
		set("concurrency", 10)
		set("workers", 1)
		set("worker-queues", false)
		set("work-duration", time.Duration(0))
	case "cluster":
		set("jobs", 50000)
		set("concurrency", 50)
		set("workers", 5)
		set("worker-queues", true)
		set("work-duration", time.Duration(0))
	case "failure":
		set("jobs", 10000)
		set("concurrency", 20)
		set("workers", 3)
		set("worker-queues", false)
		set("work-duration", 5*time.Millisecond)
	default:
		return fmt.Errorf("unknown preset %q (expected single-node, cluster, or failure)", benchPreset)
	}
	return nil
}

// ── main run ────────────────────────────────────────────────────────────────

func runBench(cmd *cobra.Command, args []string) error {
	if benchScenario != "" && benchPreset != "failure" {
		return fmt.Errorf("--scenario requires --preset failure")
	}
	validScenarios := map[string]bool{
		"leader-kill": true, "partition": true, "disk-full": true,
		"worker-crash": true, "slow-node": true,
	}
	if benchScenario != "" && !validScenarios[benchScenario] {
		return fmt.Errorf("unknown scenario %q", benchScenario)
	}

	fmt.Printf("Corvo Benchmark\n")
	fmt.Printf("  server:      %s\n", benchServer)
	fmt.Printf("  protocol:    %s\n", benchProtocol)
	fmt.Printf("  jobs:        %d\n", benchJobs)
	fmt.Printf("  concurrency: %d\n", benchConcurrency)
	fmt.Printf("  workers:     %d\n", benchWorkers)
	fmt.Printf("  worker-queues: %t\n", benchWorkerQueues)
	fmt.Printf("  repeats:     %d\n", benchRepeats)
	fmt.Printf("  queue:       %s\n", benchQueue)
	fmt.Printf("  enqueue-batch: %d\n", benchEnqBatchSize)
	fmt.Printf("  fetch-batch: %d\n", benchFetchBatchSize)
	fmt.Printf("  ack-batch:   %d\n", benchAckBatchSize)
	fmt.Printf("  work:        %s\n", benchWorkDuration.String())
	fmt.Printf("  combined:    %t\n", benchCombined)
	if benchPreset != "" {
		fmt.Printf("  preset:      %s\n", benchPreset)
	}
	if benchScenario != "" {
		fmt.Printf("  scenario:    %s\n", benchScenario)
	}
	fmt.Println()

	httpC := &http.Client{Timeout: 30 * time.Second}

	resp, err := httpC.Get(benchServer + "/healthz")
	if err != nil {
		return fmt.Errorf("cannot reach server: %w", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("server unhealthy: status %d", resp.StatusCode)
	}

	serverCfg := benchFetchServerConfig(httpC, benchServer)
	if serverCfg != nil {
		fmt.Printf("  server-mode:  %s\n", serverCfg.Mode)
		if serverCfg.Nodes > 0 {
			fmt.Printf("  nodes:        %d\n", serverCfg.Nodes)
		}
		if serverCfg.Shards > 0 {
			fmt.Printf("  raft-shards:  %d\n", serverCfg.Shards)
		}
		if serverCfg.RaftStore != "" {
			fmt.Printf("  raft-store:   %s\n", serverCfg.RaftStore)
		}
		fmt.Printf("  durable:      %t\n", serverCfg.Durable)
	}

	var baseline *benchSaveData
	if benchCompare != "" {
		b, err := os.ReadFile(benchCompare)
		if err != nil {
			return fmt.Errorf("read baseline: %w", err)
		}
		baseline = &benchSaveData{}
		if err := json.Unmarshal(b, baseline); err != nil {
			return fmt.Errorf("parse baseline: %w", err)
		}
	}

	var faultTracker *benchFaultTracker
	if benchScenario != "" {
		faultTracker = &benchFaultTracker{}
	}

	var enqSummary, lcSummary, combinedSummary benchRunSummary
	var enqServerMetrics, lcServerMetrics, combinedServerMetrics *benchServerMetrics

	run := func(mode string) {
		if benchProtocol == "matrix" {
			fmt.Printf("\n=== Protocol: %s ===\n", mode)
		}
		enqRuns := make([]benchRunSummary, 0, benchRepeats)
		lcRuns := make([]benchRunSummary, 0, benchRepeats)
		combinedRuns := make([]benchRunSummary, 0, benchRepeats)
		for i := 1; i <= benchRepeats; i++ {
			benchClearQueues(httpC, benchServer, benchQueue, benchWorkers, benchWorkerQueues)
			if benchRepeats > 1 {
				fmt.Printf("\n-- Run %d/%d --\n", i, benchRepeats)
			}

			if faultTracker != nil && i == 1 {
				go benchRunFaultScenario(faultTracker)
			}

			if benchCombined {
				fmt.Println("=== Combined Benchmark (enqueue + fetch + ack) ===")
				cbStatsBefore := benchFetchServerStats(httpC, benchServer)
				cbStart := time.Now()
				cbResult := benchDoCombined(mode, httpC, benchServer, benchJobs, benchConcurrency, benchWorkers, benchQueue, benchEnqBatchSize, benchFetchBatchSize, benchAckBatchSize, benchWorkDuration, benchWorkerQueues)
				cbWall := time.Since(cbStart)
				cbStatsAfter := benchFetchServerStats(httpC, benchServer)
				s := benchPrintStats(cbResult)
				if sm := benchComputeServerMetrics(cbStatsBefore, cbStatsAfter, cbWall); sm != nil {
					combinedServerMetrics = sm
					benchPrintServerMetrics(sm)
				}
				combinedRuns = append(combinedRuns, s)
				if i == benchRepeats {
					combinedSummary = s
				}
			} else {
				fmt.Println("=== Enqueue Benchmark ===")
				enqStatsBefore := benchFetchServerStats(httpC, benchServer)
				enqStart := time.Now()
				enqResult := benchDoEnqueue(mode, benchServer, benchJobs, benchConcurrency, benchWorkers, benchQueue, benchEnqBatchSize, benchWorkerQueues)
				enqWall := time.Since(enqStart)
				enqStatsAfter := benchFetchServerStats(httpC, benchServer)
				s := benchPrintStats(enqResult)
				if sm := benchComputeServerMetrics(enqStatsBefore, enqStatsAfter, enqWall); sm != nil {
					enqServerMetrics = sm
					benchPrintServerMetrics(sm)
				}
				enqRuns = append(enqRuns, s)
				if i == benchRepeats {
					enqSummary = s
				}

				fmt.Println("\n=== Processing Benchmark (fetch -> ack) ===")
				lcStatsBefore := benchFetchServerStats(httpC, benchServer)
				lcStart := time.Now()
				lcResult := benchDoLifecycle(mode, httpC, benchServer, benchJobs, benchWorkers, benchConcurrency, benchQueue, benchFetchBatchSize, benchAckBatchSize, benchWorkDuration, benchWorkerQueues)
				lcWall := time.Since(lcStart)
				lcStatsAfter := benchFetchServerStats(httpC, benchServer)
				s = benchPrintStats(lcResult)
				if sm := benchComputeServerMetrics(lcStatsBefore, lcStatsAfter, lcWall); sm != nil {
					lcServerMetrics = sm
					benchPrintServerMetrics(sm)
				}
				lcRuns = append(lcRuns, s)
				if i == benchRepeats {
					lcSummary = s
				}
			}

			if i < benchRepeats && benchRepeatPause > 0 {
				time.Sleep(benchRepeatPause)
			}
		}
		if benchRepeats > 1 {
			if benchCombined {
				fmt.Println("\n=== Repeat Summary: Combined ===")
				benchPrintRunAggregate(combinedRuns)
			} else {
				fmt.Println("\n=== Repeat Summary: Enqueue ===")
				benchPrintRunAggregate(enqRuns)
				fmt.Println("\n=== Repeat Summary: Lifecycle ===")
				benchPrintRunAggregate(lcRuns)
			}
		}
	}

	switch benchProtocol {
	case "rpc", "http":
		run(benchProtocol)
	case "matrix":
		run("rpc")
		run("http")
	default:
		return fmt.Errorf("invalid --protocol %q (expected rpc, http, matrix)", benchProtocol)
	}

	if faultTracker != nil {
		faultTracker.mu.Lock()
		fmt.Println("\n=== Fault Injection Report ===")
		fmt.Printf("  scenario:     %s\n", benchScenario)
		if !faultTracker.injectedAt.IsZero() {
			fmt.Printf("  injected at:  %s\n", faultTracker.injectedAt.Format(time.RFC3339))
		}
		if !faultTracker.recoveredAt.IsZero() {
			fmt.Printf("  recovered at: %s\n", faultTracker.recoveredAt.Format(time.RFC3339))
		}
		if faultTracker.recoveryMs > 0 {
			fmt.Printf("  recovery:     %dms\n", faultTracker.recoveryMs)
		}
		fmt.Printf("  errors:       %d\n", faultTracker.errorsDuringFault)
		faultTracker.mu.Unlock()
	}

	// Save results.
	saveData := benchBuildSaveData(enqSummary, lcSummary, combinedSummary, faultTracker, serverCfg, enqServerMetrics, lcServerMetrics, combinedServerMetrics)
	savePath := benchSave
	if savePath == "" {
		savePath = fmt.Sprintf("bench-%s.json", time.Now().Format("20060102-150405"))
	}
	if err := benchWriteJSON(savePath, saveData); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not save results: %v\n", err)
	} else {
		fmt.Printf("\nResults saved to %s\n", savePath)
	}

	if baseline != nil {
		fmt.Println()
		benchPrintComparison(baseline, saveData)
	}

	return nil
}

// ── enqueue benchmark ───────────────────────────────────────────────────────

func benchDoEnqueue(protocol, serverURL string, total, concurrency, workers int, queue string, enqueueBatchSize int, workerQueues bool) benchResult {
	if enqueueBatchSize <= 0 {
		enqueueBatchSize = 1
	}
	lats := make([]time.Duration, total)
	serverLats := make([]time.Duration, total)
	var idx atomic.Int64
	var queueRR atomic.Int64
	var overloads atomic.Int64
	var wg sync.WaitGroup
	var rpcClients []*worker.Client
	if protocol != "http" {
		rpcClients = benchNewRPCClientPool(serverURL, concurrency)
	}

	perWorker := total / concurrency
	remainder := total % concurrency

	start := time.Now()

	for i := range concurrency {
		n := perWorker
		if i < remainder {
			n++
		}
		wg.Add(1)
		go func(count int, goroutineIdx int) {
			defer wg.Done()
			if protocol == "http" && enqueueBatchSize == 1 {
				c := client.New(serverURL)
				for range count {
					targetQueue := queue
					if workerQueues {
						targetQueue = benchWorkerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
					}
					opStart := time.Now()
					_, err := c.Enqueue(targetQueue, map[string]any{})
					if err != nil {
						if benchIsOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(benchOverloadBackoff(overloads.Load()))
							continue
						}
						fmt.Fprintf(os.Stderr, "enqueue error: %v\n", err)
						continue
					}
					pos := idx.Add(1) - 1
					if pos >= int64(total) {
						break
					}
					lats[pos] = time.Since(opStart)
					if c.ServerDuration > 0 {
						serverLats[pos] = c.ServerDuration
					}
				}
				return
			}
			if protocol == "http" {
				c := client.New(serverURL)
				remaining := count
				for remaining > 0 {
					n := enqueueBatchSize
					if n > remaining {
						n = remaining
					}
					jobs := make([]client.BatchJob, 0, n)
					for range n {
						targetQueue := queue
						if workerQueues {
							targetQueue = benchWorkerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
						}
						jobs = append(jobs, client.BatchJob{Queue: targetQueue, Payload: map[string]any{}})
					}
					opStart := time.Now()
					resp, err := c.EnqueueBatch(client.BatchRequest{Jobs: jobs})
					if err != nil {
						if benchIsOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(benchOverloadBackoff(overloads.Load()))
							continue
						}
						fmt.Fprintf(os.Stderr, "enqueue batch error: %v\n", err)
						continue
					}
					lat := time.Since(opStart)
					srvDur := c.ServerDuration
					for range resp.JobIDs {
						pos := idx.Add(1) - 1
						if pos >= int64(total) {
							break
						}
						lats[pos] = lat
						if srvDur > 0 {
							serverLats[pos] = srvDur
						}
						remaining--
					}
				}
				return
			}

			wc := rpcClients[goroutineIdx%len(rpcClients)]
			ctx := context.Background()
			stream := wc.OpenLifecycleStream(ctx)
			defer stream.Close()
			var streamErrs int64
			var reqID uint64 = 1

			remaining := count
			for remaining > 0 {
				n := enqueueBatchSize
				if n > remaining {
					n = remaining
				}
				enqueues := make([]worker.LifecycleEnqueueItem, 0, n)
				for range n {
					targetQueue := queue
					if workerQueues {
						targetQueue = benchWorkerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
					}
					enqueues = append(enqueues, worker.LifecycleEnqueueItem{
						Queue:   targetQueue,
						Payload: json.RawMessage(`{}`),
					})
				}
				opStart := time.Now()
				resp, err := stream.Exchange(worker.LifecycleRequest{
					RequestID: reqID,
					Enqueues:  enqueues,
				})
				reqID++
				if err != nil {
					if benchIsOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					streamErrs++
					if streamErrs <= 3 || streamErrs%1000 == 0 {
						fmt.Fprintf(os.Stderr, "enqueue stream error: %v\n", err)
					}
					stream.Close()
					stream = wc.OpenLifecycleStream(ctx)
					time.Sleep(2 * time.Millisecond)
					continue
				}
				if resp.Error != "" {
					if benchIsOverloadMsg(resp.Error) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					fmt.Fprintf(os.Stderr, "enqueue stream frame error: %s\n", resp.Error)
					continue
				}
				lat := time.Since(opStart)
				for range resp.EnqueuedJobIDs {
					pos := idx.Add(1) - 1
					if pos >= int64(total) {
						break
					}
					lats[pos] = lat
					remaining--
				}
			}
		}(n, i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	actual := int(idx.Load())
	fmt.Printf("  completed: %d/%d in %s\n", actual, total, elapsed.Round(time.Millisecond))
	if n := overloads.Load(); n > 0 {
		fmt.Printf("  overloaded: %d\n", n)
	}
	// Trim serverLats to only include entries that have data.
	srvActual := serverLats[:actual]
	var srvCount int
	for _, d := range srvActual {
		if d > 0 {
			srvCount++
		}
	}
	var srvResult []time.Duration
	if srvCount > 0 {
		srvResult = make([]time.Duration, 0, srvCount)
		for _, d := range srvActual {
			if d > 0 {
				srvResult = append(srvResult, d)
			}
		}
	}
	return benchResult{lats: lats[:actual], serverLats: srvResult, elapsed: elapsed}
}

// ── lifecycle benchmark ─────────────────────────────────────────────────────

func benchDoLifecycle(protocol string, httpC *http.Client, serverURL string, total, workers, concurrency int, queue string, fetchBatchSize, ackBatchSize int, workDuration time.Duration, workerQueues bool) benchResult {
	if fetchBatchSize <= 0 {
		fetchBatchSize = 1
	}
	if ackBatchSize <= 0 {
		ackBatchSize = 1
	}
	if workers <= 0 {
		workers = 1
	}
	if concurrency <= 0 {
		concurrency = 1
	}
	lats := make([]time.Duration, total)
	var idx atomic.Int64
	var overloads atomic.Int64
	var wg sync.WaitGroup
	var completedMu sync.Mutex
	completedIDs := make(map[string]struct{}, total)
	var rpcClients []*worker.Client
	if protocol != "http" {
		rpcClients = benchNewRPCClientPool(serverURL, workers*concurrency)
	}
	isCompleted := func(id string) bool {
		completedMu.Lock()
		_, ok := completedIDs[id]
		completedMu.Unlock()
		return ok
	}
	markCompleted := func(id string) bool {
		completedMu.Lock()
		if _, ok := completedIDs[id]; ok {
			completedMu.Unlock()
			return false
		}
		completedIDs[id] = struct{}{}
		completedMu.Unlock()
		return true
	}
	completedCount := func() int {
		completedMu.Lock()
		n := len(completedIDs)
		completedMu.Unlock()
		return n
	}

	totalStreams := workers * concurrency
	perStream := total / totalStreams
	remainder := total % totalStreams

	start := time.Now()

	for i := range totalStreams {
		n := perStream
		if i < remainder {
			n++
		}
		workerIdx := i / concurrency
		workerID := fmt.Sprintf("bench-worker-%d", workerIdx)
		workerQueue := queue
		if workerQueues {
			workerQueue = benchWorkerQueueName(queue, workers, workerIdx)
		}
		wg.Add(1)
		go func(count int, wid, wq string, streamIdx int) {
			defer wg.Done()
			if protocol == "http" {
				remaining := count
				pending := make([]benchFetchedItem, 0, ackBatchSize*2)
				for remaining > 0 || len(pending) > 0 {
					if len(pending) > 0 {
						ackN := ackBatchSize
						if ackN > len(pending) {
							ackN = len(pending)
						}
						ids := make([]string, 0, ackN)
						for j := 0; j < ackN; j++ {
							ids = append(ids, pending[j].jobID)
						}
						if err := benchAckJobs(httpC, serverURL, ids); err != nil {
							if benchIsOverloadErr(err) {
								overloads.Add(1)
								time.Sleep(benchOverloadBackoff(overloads.Load()))
								continue
							}
							fmt.Fprintf(os.Stderr, "http ack batch error: %v\n", err)
							time.Sleep(1 * time.Millisecond)
							continue
						}
						now := time.Now()
						for j := 0; j < ackN; j++ {
							pos := idx.Add(1) - 1
							if pos >= int64(total) {
								break
							}
							lats[pos] = now.Sub(pending[j].started)
						}
						pending = pending[ackN:]
					}
					if remaining <= 0 {
						continue
					}
					fetchN := fetchBatchSize
					if fetchN > remaining {
						fetchN = remaining
					}
					fetched, err := benchFetchJobs(httpC, serverURL, wq, wid, fetchN)
					if err != nil {
						if benchIsOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(benchOverloadBackoff(overloads.Load()))
						} else {
							time.Sleep(1 * time.Millisecond)
						}
						continue
					}
					for _, it := range fetched {
						if workDuration > 0 {
							time.Sleep(workDuration)
						}
						pending = append(pending, it)
						remaining--
					}
				}
				return
			}
			wc := rpcClients[streamIdx%len(rpcClients)]
			ctx := context.Background()
			stream := wc.OpenLifecycleStream(ctx)
			defer stream.Close()
			var streamErrs int64

			pendingOrder := make([]string, 0, ackBatchSize*2)
			pendingStart := make(map[string]time.Time, ackBatchSize*2)
			ackMisses := make(map[string]int, ackBatchSize*2)
			var requestID uint64 = 1

			for {
				doneNow := completedCount()
				if doneNow >= total && len(pendingOrder) == 0 {
					break
				}

				ackN := ackBatchSize
				if ackN > len(pendingOrder) {
					ackN = len(pendingOrder)
				}
				ackIDs := pendingOrder[:ackN]
				acks := make([]worker.AckBatchItem, 0, ackN)
				for _, id := range ackIDs {
					acks = append(acks, worker.AckBatchItem{
						JobID:  id,
						Result: json.RawMessage(`{}`),
					})
				}

				remainingToComplete := total - doneNow
				fetchN := fetchBatchSize
				if fetchN > remainingToComplete {
					fetchN = remainingToComplete
				}
				if fetchN < 0 {
					fetchN = 0
				}

				frameStart := time.Now()
				resp, err := stream.Exchange(worker.LifecycleRequest{
					RequestID:    requestID,
					Queues:       []string{wq},
					WorkerID:     wid,
					Hostname:     "bench-host",
					LeaseSeconds: 30,
					FetchCount:   fetchN,
					Acks:         acks,
				})
				requestID++
				if err != nil {
					if benchIsOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					streamErrs++
					if streamErrs <= 3 || streamErrs%1000 == 0 {
						fmt.Fprintf(os.Stderr, "lifecycle stream error: %v\n", err)
					}
					stream.Close()
					stream = wc.OpenLifecycleStream(ctx)
					time.Sleep(2 * time.Millisecond)
					continue
				}
				if resp.Error != "" {
					if benchIsOverloadMsg(resp.Error) {
						overloads.Add(1)
					} else {
						streamErrs++
						if streamErrs <= 3 || streamErrs%1000 == 0 {
							fmt.Fprintf(os.Stderr, "lifecycle stream frame error: %s\n", resp.Error)
						}
					}
					time.Sleep(benchOverloadBackoff(overloads.Load()))
				}

				acked := resp.Acked
				if acked > len(ackIDs) {
					acked = len(ackIDs)
				}
				now := time.Now()
				for j := 0; j < acked; j++ {
					id := ackIDs[j]
					if isCompleted(id) {
						continue
					}
					started, ok := pendingStart[id]
					if !ok {
						continue
					}
					if !markCompleted(id) {
						delete(pendingStart, id)
						delete(ackMisses, id)
						continue
					}
					pos := idx.Add(1) - 1
					if pos >= int64(total) {
						break
					}
					lats[pos] = now.Sub(started)
					delete(pendingStart, id)
					delete(ackMisses, id)
				}
				pendingOrder = pendingOrder[acked:]

				if resp.Error == "" && acked < len(ackIDs) {
					drop := map[string]struct{}{}
					for _, id := range ackIDs[acked:] {
						ackMisses[id]++
						if ackMisses[id] < 3 {
							continue
						}
						drop[id] = struct{}{}
						delete(pendingStart, id)
						delete(ackMisses, id)
					}
					if len(drop) > 0 {
						filtered := pendingOrder[:0]
						for _, id := range pendingOrder {
							if _, ok := drop[id]; ok {
								continue
							}
							filtered = append(filtered, id)
						}
						pendingOrder = filtered
					}
				}

				for _, fetched := range resp.Jobs {
					if completedCount() >= total {
						break
					}
					if workDuration > 0 {
						time.Sleep(workDuration)
					}
					if fetched.JobID == "" {
						continue
					}
					if isCompleted(fetched.JobID) {
						continue
					}
					if _, pending := pendingStart[fetched.JobID]; pending {
						continue
					}
					pendingOrder = append(pendingOrder, fetched.JobID)
					pendingStart[fetched.JobID] = frameStart
				}
			}
		}(n, workerID, workerQueue, i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	actual := int(idx.Load())
	fmt.Printf("  completed: %d/%d in %s\n", actual, total, elapsed.Round(time.Millisecond))
	if n := overloads.Load(); n > 0 {
		fmt.Printf("  overloaded: %d\n", n)
	}
	return benchResult{lats: lats[:actual], elapsed: elapsed}
}

// ── combined benchmark ──────────────────────────────────────────────────────

// benchDoCombined runs enqueue producers and lifecycle workers concurrently,
// measuring end-to-end throughput. Latency is measured per-job from enqueue
// submission to ack confirmation.
func benchDoCombined(protocol string, httpC *http.Client, serverURL string, total, concurrency, workers int, queue string, enqueueBatchSize, fetchBatchSize, ackBatchSize int, workDuration time.Duration, workerQueues bool) benchResult {
	if enqueueBatchSize <= 0 {
		enqueueBatchSize = 1
	}
	if fetchBatchSize <= 0 {
		fetchBatchSize = 1
	}
	if ackBatchSize <= 0 {
		ackBatchSize = 1
	}
	if workers <= 0 {
		workers = 1
	}
	if concurrency <= 0 {
		concurrency = 1
	}

	// Track enqueue timestamps for e2e latency calculation.
	var enqTimeMu sync.RWMutex
	enqTimes := make(map[string]time.Time, total)
	setEnqTime := func(id string, t time.Time) {
		enqTimeMu.Lock()
		enqTimes[id] = t
		enqTimeMu.Unlock()
	}
	getEnqTime := func(id string) (time.Time, bool) {
		enqTimeMu.RLock()
		t, ok := enqTimes[id]
		enqTimeMu.RUnlock()
		return t, ok
	}

	// e2e latencies: one per completed job.
	lats := make([]time.Duration, total)
	var latIdx atomic.Int64

	// Counters.
	var enqueued atomic.Int64
	var overloads atomic.Int64

	// Completed tracking for lifecycle side.
	// Use sync.Map for lock-free reads + atomic counter for fast count.
	var completedIDs sync.Map
	var completedN atomic.Int64
	isCompleted := func(id string) bool {
		_, ok := completedIDs.Load(id)
		return ok
	}
	markCompleted := func(id string) bool {
		if _, loaded := completedIDs.LoadOrStore(id, struct{}{}); loaded {
			return false
		}
		completedN.Add(1)
		return true
	}
	completedCount := func() int {
		return int(completedN.Load())
	}

	var producerClients, workerClients []*worker.Client
	if protocol != "http" {
		// Separate pools for producers and workers — matching real-world usage
		// where client SDK and worker SDK use different connections. This avoids
		// head-of-line blocking between enqueue and fetch frames on the same stream.
		producerClients = benchNewRPCClientPool(serverURL, concurrency)
		workerClients = benchNewRPCClientPool(serverURL, workers*concurrency)
	}
	var queueRR atomic.Int64

	var wg sync.WaitGroup
	start := time.Now()

	// ── Enqueue producers ──
	perProducer := total / concurrency
	producerRemainder := total % concurrency
	for i := range concurrency {
		n := perProducer
		if i < producerRemainder {
			n++
		}
		wg.Add(1)
		go func(count int, goroutineIdx int) {
			defer wg.Done()

			if protocol == "http" {
				c := client.New(serverURL)
				remaining := count
				for remaining > 0 {
					batchN := enqueueBatchSize
					if batchN > remaining {
						batchN = remaining
					}
					jobs := make([]client.BatchJob, 0, batchN)
					for range batchN {
						targetQueue := queue
						if workerQueues {
							targetQueue = benchWorkerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
						}
						jobs = append(jobs, client.BatchJob{Queue: targetQueue, Payload: map[string]any{}})
					}
					opStart := time.Now()
					resp, err := c.EnqueueBatch(client.BatchRequest{Jobs: jobs})
					if err != nil {
						if benchIsOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(benchOverloadBackoff(overloads.Load()))
							continue
						}
						fmt.Fprintf(os.Stderr, "combined enqueue error: %v\n", err)
						continue
					}
					for _, id := range resp.JobIDs {
						setEnqTime(id, opStart)
						enqueued.Add(1)
						remaining--
					}
				}
				return
			}

			// RPC stream path.
			wc := producerClients[goroutineIdx%len(producerClients)]
			ctx := context.Background()
			stream := wc.OpenLifecycleStream(ctx)
			defer stream.Close()
			var streamErrs int64
			var reqID uint64 = 1

			remaining := count
			for remaining > 0 {
				batchN := enqueueBatchSize
				if batchN > remaining {
					batchN = remaining
				}
				enqueues := make([]worker.LifecycleEnqueueItem, 0, batchN)
				for range batchN {
					targetQueue := queue
					if workerQueues {
						targetQueue = benchWorkerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
					}
					enqueues = append(enqueues, worker.LifecycleEnqueueItem{
						Queue:   targetQueue,
						Payload: json.RawMessage(`{}`),
					})
				}
				opStart := time.Now()
				resp, err := stream.Exchange(worker.LifecycleRequest{
					RequestID: reqID,
					Enqueues:  enqueues,
				})
				reqID++
				if err != nil {
					if benchIsOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					streamErrs++
					if streamErrs <= 3 || streamErrs%1000 == 0 {
						fmt.Fprintf(os.Stderr, "combined enqueue stream error: %v\n", err)
					}
					stream.Close()
					stream = wc.OpenLifecycleStream(ctx)
					time.Sleep(2 * time.Millisecond)
					continue
				}
				if resp.Error != "" {
					if benchIsOverloadMsg(resp.Error) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					fmt.Fprintf(os.Stderr, "combined enqueue frame error: %s\n", resp.Error)
					continue
				}
				for _, id := range resp.EnqueuedJobIDs {
					setEnqTime(id, opStart)
					enqueued.Add(1)
					remaining--
				}
			}
		}(n, i)
	}

	// ── Lifecycle workers (fetch + ack) ──
	// Match producer concurrency: one consumer stream per producer goroutine.
	// Too few streams can't keep up with producers; too many generate empty
	// raft fetches. Each stream uses fetchBatchSize to grab multiple jobs per
	// round-trip.
	threshold := int64(total / 10)
	if threshold < 1 {
		threshold = 1
	}

	// Use the larger of fetchBatchSize and ackBatchSize for combined mode
	// to maximize jobs processed per raft round-trip.
	combinedFetchBatch := fetchBatchSize
	if combinedFetchBatch < ackBatchSize {
		combinedFetchBatch = ackBatchSize
	}

	totalStreams := concurrency
	for i := range totalStreams {
		workerIdx := i % max(workers, 1)
		workerID := fmt.Sprintf("bench-worker-%d", workerIdx)
		workerQueue := queue
		if workerQueues {
			workerQueue = benchWorkerQueueName(queue, workers, workerIdx)
		}
		wg.Add(1)
		go func(wid, wq string, streamIdx int) {
			defer wg.Done()

			// Wait for producers to get ahead before fetching.
			for enqueued.Load() < threshold {
				time.Sleep(5 * time.Millisecond)
			}

			if protocol == "http" {
				pending := make([]benchFetchedItem, 0, ackBatchSize*2)
				for {
					done := completedCount()
					if done >= total && len(pending) == 0 {
						break
					}

					// Ack pending.
					if len(pending) > 0 {
						ackN := ackBatchSize
						if ackN > len(pending) {
							ackN = len(pending)
						}
						ids := make([]string, 0, ackN)
						for j := 0; j < ackN; j++ {
							ids = append(ids, pending[j].jobID)
						}
						if err := benchAckJobs(httpC, serverURL, ids); err != nil {
							if benchIsOverloadErr(err) {
								overloads.Add(1)
								time.Sleep(benchOverloadBackoff(overloads.Load()))
								continue
							}
							fmt.Fprintf(os.Stderr, "combined http ack error: %v\n", err)
							time.Sleep(1 * time.Millisecond)
							continue
						}
						now := time.Now()
						for j := 0; j < ackN; j++ {
							id := pending[j].jobID
							if markCompleted(id) {
								if enqTime, ok := getEnqTime(id); ok {
									pos := latIdx.Add(1) - 1
									if pos < int64(total) {
										lats[pos] = now.Sub(enqTime)
									}
								}
							}
						}
						pending = pending[ackN:]
					}

					// Fetch more.
					remaining := total - completedCount()
					if remaining <= 0 {
						continue
					}
					fetchN := combinedFetchBatch
					if fetchN > remaining {
						fetchN = remaining
					}
					fetched, err := benchFetchJobs(httpC, serverURL, wq, wid, fetchN)
					if err != nil {
						if benchIsOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(benchOverloadBackoff(overloads.Load()))
						} else {
							time.Sleep(1 * time.Millisecond)
						}
						continue
					}
					if len(fetched) == 0 && len(pending) == 0 {
						time.Sleep(5 * time.Millisecond)
					}
					for _, it := range fetched {
						if workDuration > 0 {
							time.Sleep(workDuration)
						}
						pending = append(pending, it)
					}
				}
				return
			}

			// RPC stream path.
			wc := workerClients[streamIdx%len(workerClients)]
			ctx := context.Background()
			stream := wc.OpenLifecycleStream(ctx)
			defer stream.Close()
			var streamErrs int64

			pendingOrder := make([]string, 0, ackBatchSize*2)
			pendingStart := make(map[string]time.Time, ackBatchSize*2)
			ackMisses := make(map[string]int, ackBatchSize*2)
			var requestID uint64 = 1
			var totalFetched, totalAcked, emptyFetches int
			var lastProgressCount int
			lastProgressTime := time.Now()
			var logTicker int

			for {
				doneNow := completedCount()
				if doneNow >= total && len(pendingOrder) == 0 {
					break
				}

				// Periodic progress logging.
				logTicker++
				if logTicker%500 == 0 {
					fmt.Fprintf(os.Stderr, "  [%s q=%s] completed=%d/%d pending=%d fetched=%d acked=%d empty=%d errs=%d\n",
						wid, wq, doneNow, total, len(pendingOrder), totalFetched, totalAcked, emptyFetches, streamErrs)
				}

				// Stall detection.
				if doneNow != lastProgressCount {
					lastProgressCount = doneNow
					lastProgressTime = time.Now()
				} else if time.Since(lastProgressTime) > 15*time.Second {
					fmt.Fprintf(os.Stderr, "  [%s q=%s] STALLED: completed=%d/%d pending=%d fetched=%d acked=%d empty=%d\n",
						wid, wq, doneNow, total, len(pendingOrder), totalFetched, totalAcked, emptyFetches)
					for _, id := range pendingOrder {
						markCompleted(id)
					}
					pendingOrder = nil
					break
				}

				ackN := ackBatchSize
				if ackN > len(pendingOrder) {
					ackN = len(pendingOrder)
				}
				ackIDs := pendingOrder[:ackN]
				acks := make([]worker.AckBatchItem, 0, ackN)
				for _, id := range ackIDs {
					acks = append(acks, worker.AckBatchItem{
						JobID:  id,
						Result: json.RawMessage(`{}`),
					})
				}

				remainingToComplete := total - doneNow
				fetchN := combinedFetchBatch
				if fetchN > remainingToComplete {
					fetchN = remainingToComplete
				}
				if fetchN < 0 {
					fetchN = 0
				}

				resp, err := stream.Exchange(worker.LifecycleRequest{
					RequestID:    requestID,
					Queues:       []string{wq},
					WorkerID:     wid,
					Hostname:     "bench-host",
					LeaseSeconds: 30,
					FetchCount:   fetchN,
					Acks:         acks,
				})
				requestID++
				if err != nil {
					if benchIsOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(benchOverloadBackoff(overloads.Load()))
						continue
					}
					streamErrs++
					if streamErrs <= 3 || streamErrs%1000 == 0 {
						fmt.Fprintf(os.Stderr, "combined lifecycle stream error: %v\n", err)
					}
					stream.Close()
					stream = wc.OpenLifecycleStream(ctx)
					time.Sleep(2 * time.Millisecond)
					continue
				}
				if resp.Error != "" {
					if benchIsOverloadMsg(resp.Error) {
						overloads.Add(1)
					} else {
						streamErrs++
						if streamErrs <= 3 || streamErrs%1000 == 0 {
							fmt.Fprintf(os.Stderr, "combined lifecycle frame error: %s\n", resp.Error)
						}
					}
					time.Sleep(benchOverloadBackoff(overloads.Load()))
				}

				acked := resp.Acked
				if acked > len(ackIDs) {
					acked = len(ackIDs)
				}
				now := time.Now()
				for j := 0; j < acked; j++ {
					id := ackIDs[j]
					if isCompleted(id) {
						continue
					}
					if !markCompleted(id) {
						delete(pendingStart, id)
						delete(ackMisses, id)
						continue
					}
					// Use enqueue time for e2e latency.
					if enqTime, ok := getEnqTime(id); ok {
						pos := latIdx.Add(1) - 1
						if pos < int64(total) {
							lats[pos] = now.Sub(enqTime)
						}
					}
					delete(pendingStart, id)
					delete(ackMisses, id)
				}
				totalAcked += acked
				pendingOrder = pendingOrder[acked:]

				if resp.Error == "" && acked < len(ackIDs) {
					drop := map[string]struct{}{}
					for _, id := range ackIDs[acked:] {
						ackMisses[id]++
						if ackMisses[id] < 3 {
							continue
						}
						drop[id] = struct{}{}
						delete(pendingStart, id)
						delete(ackMisses, id)
						// Count dropped jobs as completed to prevent bench from hanging.
						markCompleted(id)
					}
					if len(drop) > 0 {
						filtered := pendingOrder[:0]
						for _, id := range pendingOrder {
							if _, ok := drop[id]; ok {
								continue
							}
							filtered = append(filtered, id)
						}
						pendingOrder = filtered
					}
				}

				fetchedCount := 0
				doneCheck := completedCount()
				for _, fetched := range resp.Jobs {
					if doneCheck >= total {
						break
					}
					if workDuration > 0 {
						time.Sleep(workDuration)
					}
					if fetched.JobID == "" {
						continue
					}
					if _, pending := pendingStart[fetched.JobID]; pending {
						continue
					}
					// Always add to pending so it gets acked, even if another
					// worker already completed it. The server assigned this job
					// to us — we must ack it to release the active lease.
					pendingOrder = append(pendingOrder, fetched.JobID)
					pendingStart[fetched.JobID] = now
					fetchedCount++
				}
				totalFetched += fetchedCount
				if fetchedCount == 0 && len(resp.Jobs) == 0 {
					emptyFetches++
				}
				// Back off when no jobs available to avoid hammering raft with empty fetches.
				if fetchedCount == 0 && len(pendingOrder) == 0 {
					time.Sleep(5 * time.Millisecond)
				}
			}
		}(workerID, workerQueue, i)
	}

	wg.Wait()
	elapsed := time.Since(start)

	actual := int(latIdx.Load())
	fmt.Printf("  enqueued:  %d\n", enqueued.Load())
	fmt.Printf("  completed: %d/%d in %s\n", actual, total, elapsed.Round(time.Millisecond))
	fmt.Printf("  acked:     %d/%d\n", completedN.Load(), total)
	if n := overloads.Load(); n > 0 {
		fmt.Printf("  overloaded: %d\n", n)
	}
	return benchResult{lats: lats[:actual], elapsed: elapsed}
}

// ── HTTP helpers ────────────────────────────────────────────────────────────

func benchFetchJobs(httpC *http.Client, serverURL, queue, workerID string, count int) ([]benchFetchedItem, error) {
	body, _ := json.Marshal(map[string]any{
		"queues":    []string{queue},
		"worker_id": workerID,
		"hostname":  "bench-host",
		"timeout":   1,
		"count":     count,
	})
	opStart := time.Now()
	resp, err := httpC.Post(serverURL+"/api/v1/fetch/batch", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("fetch batch request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("fetch batch status %d: %s", resp.StatusCode, data)
	}

	var result struct {
		Jobs []struct {
			JobID string `json:"job_id"`
		} `json:"jobs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("fetch batch decode: %w", err)
	}

	items := make([]benchFetchedItem, 0, len(result.Jobs))
	for _, j := range result.Jobs {
		if j.JobID == "" {
			continue
		}
		items = append(items, benchFetchedItem{jobID: j.JobID, started: opStart})
	}
	return items, nil
}

func benchAckJob(httpC *http.Client, serverURL, jobID string) error {
	body, _ := json.Marshal(map[string]any{})
	resp, err := httpC.Post(serverURL+"/api/v1/ack/"+jobID, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("ack request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("ack status %d: %s", resp.StatusCode, data)
	}
	return nil
}

func benchAckJobs(httpC *http.Client, serverURL string, jobIDs []string) error {
	if len(jobIDs) == 1 {
		return benchAckJob(httpC, serverURL, jobIDs[0])
	}
	acks := make([]map[string]any, 0, len(jobIDs))
	for _, id := range jobIDs {
		acks = append(acks, map[string]any{"job_id": id})
	}
	body, _ := json.Marshal(map[string]any{"acks": acks})
	resp, err := httpC.Post(serverURL+"/api/v1/ack/batch", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("ack batch request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("ack batch status %d: %s", resp.StatusCode, data)
	}
	return nil
}

func benchClearQueue(httpC *http.Client, serverURL, queue string) {
	req, _ := http.NewRequest("POST", serverURL+"/api/v1/queues/"+queue+"/clear", nil)
	resp, err := httpC.Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}

func benchClearQueues(httpC *http.Client, serverURL, baseQueue string, workers int, workerQueues bool) {
	if !workerQueues || workers <= 1 {
		benchClearQueue(httpC, serverURL, baseQueue)
		return
	}
	for i := 0; i < workers; i++ {
		benchClearQueue(httpC, serverURL, benchWorkerQueueName(baseQueue, workers, i))
	}
}

// ── RPC client pool ─────────────────────────────────────────────────────────

func benchNewRPCClientPool(serverURL string, totalStreams int) []*worker.Client {
	if totalStreams <= 0 {
		totalStreams = 1
	}
	n := (totalStreams + benchStreamsPerRPCClient - 1) / benchStreamsPerRPCClient
	if n < 1 {
		n = 1
	}
	clients := make([]*worker.Client, 0, n)
	for range n {
		clients = append(clients, worker.New(serverURL))
	}
	return clients
}

// ── stats / summary ─────────────────────────────────────────────────────────

func benchSummarize(r benchResult) benchRunSummary {
	if len(r.lats) == 0 {
		return benchRunSummary{}
	}
	slices.Sort(r.lats)

	n := len(r.lats)
	opsPerSec := float64(n) / r.elapsed.Seconds()

	var sum time.Duration
	for _, l := range r.lats {
		sum += l
	}
	avg := sum / time.Duration(n)

	// Compute standard deviation.
	var variance float64
	avgF := float64(avg)
	for _, l := range r.lats {
		diff := float64(l) - avgF
		variance += diff * diff
	}
	variance /= float64(n)
	stddev := time.Duration(math.Sqrt(variance))

	// Coefficient of variation (stddev / mean * 100).
	var cvPct float64
	if avg > 0 {
		cvPct = float64(stddev) / float64(avg) * 100
	}

	// Compute server-side CV if available.
	var serverCv float64
	if len(r.serverLats) > 0 {
		var sSum time.Duration
		for _, l := range r.serverLats {
			sSum += l
		}
		sAvg := float64(sSum) / float64(len(r.serverLats))
		var sVar float64
		for _, l := range r.serverLats {
			diff := float64(l) - sAvg
			sVar += diff * diff
		}
		sVar /= float64(len(r.serverLats))
		if sAvg > 0 {
			serverCv = math.Sqrt(sVar) / sAvg * 100
		}
	}

	return benchRunSummary{
		opsPerSec:   opsPerSec,
		avg:         avg,
		p50:         r.lats[n*50/100],
		p90:         r.lats[n*90/100],
		p99:         r.lats[n*99/100],
		min:         r.lats[0],
		max:         r.lats[n-1],
		stddev:      stddev,
		cvPct:       cvPct,
		serverCvPct: serverCv,
		completed:   n,
	}
}

func benchPrintStats(r benchResult) benchRunSummary {
	if len(r.lats) == 0 {
		fmt.Println("  no successful operations")
		return benchRunSummary{}
	}

	s := benchSummarize(r)
	fmt.Printf("  ops/sec: %.1f\n", s.opsPerSec)
	fmt.Printf("  avg:     %s\n", s.avg.Round(time.Microsecond))
	fmt.Printf("  p50:     %s\n", s.p50.Round(time.Microsecond))
	fmt.Printf("  p90:     %s\n", s.p90.Round(time.Microsecond))
	fmt.Printf("  p99:     %s\n", s.p99.Round(time.Microsecond))
	fmt.Printf("  min:     %s\n", s.min.Round(time.Microsecond))
	fmt.Printf("  max:     %s\n", s.max.Round(time.Microsecond))
	fmt.Printf("  stddev:  %s\n", s.stddev.Round(time.Microsecond))
	fmt.Printf("  cv:      %.1f%%\n", s.cvPct)
	if s.serverCvPct > 0 {
		fmt.Printf("  srv cv:  %.1f%%\n", s.serverCvPct)
	}
	return s
}

func benchPrintServerMetrics(sm *benchServerMetrics) {
	fmt.Printf("  srv cpu:  %.1f%%\n", sm.cpuPct)
	fmt.Printf("  srv rss:  %.0fMB\n", sm.rssMB)
	fmt.Printf("  srv gc99: %.1fms\n", float64(sm.gcP99Us)/1000.0)
}

func benchPrintRunAggregate(runs []benchRunSummary) {
	if len(runs) == 0 {
		fmt.Println("  no runs")
		return
	}
	opsVals := make([]float64, 0, len(runs))
	p99Vals := make([]time.Duration, 0, len(runs))
	for _, r := range runs {
		if r.completed == 0 {
			continue
		}
		opsVals = append(opsVals, r.opsPerSec)
		p99Vals = append(p99Vals, r.p99)
	}
	if len(opsVals) == 0 {
		fmt.Println("  no successful runs")
		return
	}
	slices.Sort(opsVals)
	slices.Sort(p99Vals)
	medianOps := opsVals[len(opsVals)/2]
	p90Ops := opsVals[benchPercentileIndex(len(opsVals), 90)]
	medianP99 := p99Vals[len(p99Vals)/2]
	p90P99 := p99Vals[benchPercentileIndex(len(p99Vals), 90)]
	fmt.Printf("  ops/sec median: %.1f\n", medianOps)
	fmt.Printf("  ops/sec p90:    %.1f\n", p90Ops)
	fmt.Printf("  p99 median:     %s\n", medianP99.Round(time.Microsecond))
	fmt.Printf("  p99 p90:        %s\n", p90P99.Round(time.Microsecond))
}

// ── helpers ─────────────────────────────────────────────────────────────────

func benchWorkerQueueName(base string, workers, idx int) string {
	if workers <= 1 {
		return base
	}
	return fmt.Sprintf("%s.w%d", base, idx)
}

func benchPercentileIndex(n, p int) int {
	if n <= 1 {
		return 0
	}
	if p <= 0 {
		return 0
	}
	if p >= 100 {
		return n - 1
	}
	rank := int(math.Ceil(float64(p) / 100.0 * float64(n)))
	idx := rank - 1
	if idx < 0 {
		return 0
	}
	if idx >= n {
		return n - 1
	}
	return idx
}

func benchIsOverloadErr(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToUpper(err.Error())
	return strings.Contains(s, "OVERLOADED") ||
		strings.Contains(s, "RESOURCE_EXHAUSTED") ||
		strings.Contains(s, "429")
}

func benchIsOverloadMsg(msg string) bool {
	s := strings.ToUpper(msg)
	return strings.Contains(s, "OVERLOADED") || strings.Contains(s, "429")
}

func benchOverloadBackoff(attempt int64) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	if attempt > 8 {
		attempt = 8
	}
	d := time.Duration(1<<uint(attempt-1)) * time.Millisecond
	if d > 64*time.Millisecond {
		d = 64 * time.Millisecond
	}
	return d
}

// ── fault injection ─────────────────────────────────────────────────────────

type benchFaultTracker struct {
	mu                sync.Mutex
	injectedAt        time.Time
	recoveredAt       time.Time
	recoveryMs        int64
	errorsDuringFault int
}

func benchRunFaultScenario(ft *benchFaultTracker) {
	time.Sleep(benchFaultWarmup)

	if len(benchDockerCtrs) == 0 {
		fmt.Fprintf(os.Stderr, "warning: no --docker-container specified for scenario %q\n", benchScenario)
		return
	}
	target := benchDockerCtrs[0]

	ft.mu.Lock()
	ft.injectedAt = time.Now()
	ft.mu.Unlock()

	fmt.Printf("\n>>> Injecting fault: %s on %s\n", benchScenario, target)

	switch benchScenario {
	case "leader-kill":
		benchDockerExec("docker", "kill", target)
	case "partition":
		net := benchDockerNetwork
		if net == "" {
			net = benchDetectDockerNetwork(target)
		}
		if net != "" {
			benchDockerExec("docker", "network", "disconnect", net, target)
		}
	case "disk-full":
		benchDockerExec("docker", "exec", target, "dd", "if=/dev/zero", "of=/tmp/fill", "bs=1M", "count=512")
	case "worker-crash":
		benchDockerExec("docker", "kill", target)
	case "slow-node":
		benchDockerExec("docker", "exec", target, "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", "200ms")
	}

	time.Sleep(benchFaultDuration)

	fmt.Printf(">>> Recovering fault: %s on %s\n", benchScenario, target)

	switch benchScenario {
	case "leader-kill":
		benchDockerExec("docker", "start", target)
	case "partition":
		net := benchDockerNetwork
		if net == "" {
			net = benchDetectDockerNetwork(target)
		}
		if net != "" {
			benchDockerExec("docker", "network", "connect", net, target)
		}
	case "disk-full":
		benchDockerExec("docker", "exec", target, "rm", "/tmp/fill")
	case "worker-crash":
		benchDockerExec("docker", "start", target)
	case "slow-node":
		benchDockerExec("docker", "exec", target, "tc", "qdisc", "del", "dev", "eth0", "root", "netem")
	}

	ft.mu.Lock()
	ft.recoveredAt = time.Now()
	ft.recoveryMs = ft.recoveredAt.Sub(ft.injectedAt).Milliseconds()
	ft.mu.Unlock()
}

func benchDockerExec(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "docker exec error (%s %v): %v\n", name, args, err)
	}
}

func benchDetectDockerNetwork(container string) string {
	out, err := exec.Command("docker", "inspect", "-f", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}", container).Output()
	if err != nil {
		return ""
	}
	parts := strings.Fields(strings.TrimSpace(string(out)))
	if len(parts) > 0 {
		return parts[0]
	}
	return ""
}

// ── save / compare ──────────────────────────────────────────────────────────

func benchBuildSaveData(enq, lc, combined benchRunSummary, ft *benchFaultTracker, sc *benchServerConfig, enqSM, lcSM, combinedSM *benchServerMetrics) *benchSaveData {
	data := &benchSaveData{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Commit:    benchGitCommit(),
		Machine:   benchGetMachineInfo(),
		Server:    sc,
		Preset:    benchPreset,
		Scenario:  benchScenario,
		Config: map[string]any{
			"jobs":          benchJobs,
			"concurrency":   benchConcurrency,
			"workers":       benchWorkers,
			"worker_queues": benchWorkerQueues,
			"protocol":      benchProtocol,
			"enqueue_batch": benchEnqBatchSize,
			"fetch_batch":   benchFetchBatchSize,
			"ack_batch":     benchAckBatchSize,
			"work_duration": benchWorkDuration.String(),
			"combined":      benchCombined,
		},
	}
	if enq.completed > 0 {
		data.Enqueue = &benchPhaseResult{
			OpsPerSec:   enq.opsPerSec,
			P50Us:       enq.p50.Microseconds(),
			P90Us:       enq.p90.Microseconds(),
			P99Us:       enq.p99.Microseconds(),
			MinUs:       enq.min.Microseconds(),
			MaxUs:       enq.max.Microseconds(),
			StddevUs:    enq.stddev.Microseconds(),
			CvPct:       enq.cvPct,
			ServerCvPct: enq.serverCvPct,
			Completed:   enq.completed,
		}
		if enqSM != nil {
			data.Enqueue.ServerCPUPct = enqSM.cpuPct
			data.Enqueue.ServerRSSMB = enqSM.rssMB
			data.Enqueue.ServerGcP99Us = enqSM.gcP99Us
		}
	}
	if lc.completed > 0 {
		data.Lifecycle = &benchPhaseResult{
			OpsPerSec:   lc.opsPerSec,
			P50Us:       lc.p50.Microseconds(),
			P90Us:       lc.p90.Microseconds(),
			P99Us:       lc.p99.Microseconds(),
			MinUs:       lc.min.Microseconds(),
			MaxUs:       lc.max.Microseconds(),
			StddevUs:    lc.stddev.Microseconds(),
			CvPct:       lc.cvPct,
			ServerCvPct: lc.serverCvPct,
			Completed:   lc.completed,
		}
		if lcSM != nil {
			data.Lifecycle.ServerCPUPct = lcSM.cpuPct
			data.Lifecycle.ServerRSSMB = lcSM.rssMB
			data.Lifecycle.ServerGcP99Us = lcSM.gcP99Us
		}
	}
	if combined.completed > 0 {
		data.Combined = &benchPhaseResult{
			OpsPerSec:   combined.opsPerSec,
			P50Us:       combined.p50.Microseconds(),
			P90Us:       combined.p90.Microseconds(),
			P99Us:       combined.p99.Microseconds(),
			MinUs:       combined.min.Microseconds(),
			MaxUs:       combined.max.Microseconds(),
			StddevUs:    combined.stddev.Microseconds(),
			CvPct:       combined.cvPct,
			ServerCvPct: combined.serverCvPct,
			Completed:   combined.completed,
		}
		if combinedSM != nil {
			data.Combined.ServerCPUPct = combinedSM.cpuPct
			data.Combined.ServerRSSMB = combinedSM.rssMB
			data.Combined.ServerGcP99Us = combinedSM.gcP99Us
		}
	}
	if ft != nil {
		ft.mu.Lock()
		data.Fault = &benchFaultResult{
			InjectedAt:        ft.injectedAt.Format(time.RFC3339),
			RecoveredAt:       ft.recoveredAt.Format(time.RFC3339),
			RecoveryMs:        ft.recoveryMs,
			ErrorsDuringFault: ft.errorsDuringFault,
		}
		ft.mu.Unlock()
	}
	return data
}

func benchWriteJSON(path string, data *benchSaveData) error {
	b, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0644)
}

func benchPrintComparison(baseline, current *benchSaveData) {
	fmt.Printf("Baseline: %s on %s (%d CPU, %dGB) at %s\n",
		baseline.Commit, baseline.Machine.Hostname,
		baseline.Machine.CPUs, baseline.Machine.MemoryGB, baseline.Timestamp)
	fmt.Printf("Current:  %s on %s (%d CPU, %dGB) at %s\n",
		current.Commit, current.Machine.Hostname,
		current.Machine.CPUs, current.Machine.MemoryGB, current.Timestamp)

	if baseline.Server != nil && current.Server != nil {
		diffs := []string{}
		if baseline.Server.Mode != current.Server.Mode {
			diffs = append(diffs, fmt.Sprintf("mode: %s -> %s", baseline.Server.Mode, current.Server.Mode))
		}
		if baseline.Server.Nodes != current.Server.Nodes {
			diffs = append(diffs, fmt.Sprintf("nodes: %d -> %d", baseline.Server.Nodes, current.Server.Nodes))
		}
		if baseline.Server.Shards != current.Server.Shards {
			diffs = append(diffs, fmt.Sprintf("shards: %d -> %d", baseline.Server.Shards, current.Server.Shards))
		}
		if baseline.Server.RaftStore != current.Server.RaftStore {
			diffs = append(diffs, fmt.Sprintf("raft-store: %s -> %s", baseline.Server.RaftStore, current.Server.RaftStore))
		}
		if baseline.Server.Durable != current.Server.Durable {
			diffs = append(diffs, fmt.Sprintf("durable: %t -> %t", baseline.Server.Durable, current.Server.Durable))
		}
		if len(diffs) > 0 {
			fmt.Printf("WARNING: server config differs: %s\n", strings.Join(diffs, ", "))
		}
	}
	fmt.Println()

	fmt.Printf("%-12s | %-7s | %-10s | %-10s | %s\n", "Phase", "Metric", "Baseline", "Current", "Change")
	fmt.Printf("%-12s-+-%-7s-+-%-10s-+-%-10s-+-%s\n", "------------", "-------", "----------", "----------", "------")

	printRow := func(phase, metric string, baseVal, curVal float64, unit string, lowerBetter bool) {
		var change string
		if baseVal != 0 {
			pct := (curVal - baseVal) / baseVal * 100
			sign := "+"
			if pct < 0 {
				sign = ""
			}
			change = fmt.Sprintf("%s%.1f%%", sign, pct)
		} else {
			change = "n/a"
		}
		fmt.Printf("%-12s | %-7s | %10s | %10s | %s\n", phase, metric,
			benchFormatMetric(baseVal, unit), benchFormatMetric(curVal, unit), change)
	}

	if baseline.Enqueue != nil && current.Enqueue != nil {
		printRow("enqueue", "ops/sec", baseline.Enqueue.OpsPerSec, current.Enqueue.OpsPerSec, "", false)
		printRow("enqueue", "p99", float64(baseline.Enqueue.P99Us)/1000, float64(current.Enqueue.P99Us)/1000, "ms", true)
	}
	if baseline.Lifecycle != nil && current.Lifecycle != nil {
		printRow("lifecycle", "ops/sec", baseline.Lifecycle.OpsPerSec, current.Lifecycle.OpsPerSec, "", false)
		printRow("lifecycle", "p99", float64(baseline.Lifecycle.P99Us)/1000, float64(current.Lifecycle.P99Us)/1000, "ms", true)
	}
	if baseline.Combined != nil && current.Combined != nil {
		printRow("combined", "ops/sec", baseline.Combined.OpsPerSec, current.Combined.OpsPerSec, "", false)
		printRow("combined", "p99", float64(baseline.Combined.P99Us)/1000, float64(current.Combined.P99Us)/1000, "ms", true)
	}
}

func benchFormatMetric(val float64, unit string) string {
	if unit == "ms" {
		return fmt.Sprintf("%.1f%s", val, unit)
	}
	if val >= 1000 {
		return fmt.Sprintf("%.0f", val)
	}
	return fmt.Sprintf("%.1f", val)
}

// ── server runtime stats ────────────────────────────────────────────────────

func benchFetchServerStats(httpC *http.Client, serverURL string) *benchServerStats {
	resp, err := httpC.Get(serverURL + "/api/v1/debug/runtime")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var stats benchServerStats
	if err := json.NewDecoder(resp.Body).Decode(&stats); err != nil {
		return nil
	}
	return &stats
}

type benchServerMetrics struct {
	cpuPct  float64
	rssMB   float64
	gcP99Us int64
}

func benchComputeServerMetrics(before, after *benchServerStats, wallTime time.Duration) *benchServerMetrics {
	if before == nil || after == nil || wallTime <= 0 {
		return nil
	}
	deltaCPU := float64((after.CPUUserNs + after.CPUSysNs) - (before.CPUUserNs + before.CPUSysNs))
	procs := after.GoMaxProcs
	if procs <= 0 {
		procs = 1
	}
	cpuPct := deltaCPU / float64(wallTime.Nanoseconds()) / float64(procs) * 100

	// Peak RSS = max of before/after (heap + stack)
	beforeRSS := before.HeapInuse + before.StackInuse
	afterRSS := after.HeapInuse + after.StackInuse
	peakRSS := afterRSS
	if beforeRSS > peakRSS {
		peakRSS = beforeRSS
	}
	rssMB := float64(peakRSS) / (1024 * 1024)

	return &benchServerMetrics{
		cpuPct:  cpuPct,
		rssMB:   rssMB,
		gcP99Us: after.GCPauseP99Ns / 1000,
	}
}

// ── server config ───────────────────────────────────────────────────────────

func benchFetchServerConfig(httpC *http.Client, serverURL string) *benchServerConfig {
	resp, err := httpC.Get(serverURL + "/api/v1/cluster/status")
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not fetch server config: %v\n", err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var raw map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil
	}

	sc := &benchServerConfig{}

	if mode, ok := raw["mode"].(string); ok {
		sc.Mode = mode
	}

	// Count nodes from the nodes array (present in single/cluster mode).
	if nodes, ok := raw["nodes"].([]any); ok {
		sc.Nodes = len(nodes)
	}

	// Raft store and durable mode from top-level (single-shard cluster).
	if rs, ok := raw["raft_store"].(string); ok {
		sc.RaftStore = rs
	}
	if nosync, ok := raw["raft_nosync"].(bool); ok {
		sc.Durable = !nosync
	}

	// Multi-raft: shards count and config from first group.
	if shards, ok := raw["shards"].(float64); ok {
		sc.Shards = int(shards)
	}
	if groups, ok := raw["groups"].([]any); ok && len(groups) > 0 {
		if g0, ok := groups[0].(map[string]any); ok {
			if rs, ok := g0["raft_store"].(string); ok {
				sc.RaftStore = rs
			}
			if nosync, ok := g0["raft_nosync"].(bool); ok {
				sc.Durable = !nosync
			}
			if nodes, ok := g0["nodes"].([]any); ok {
				sc.Nodes = len(nodes)
			}
		}
	}

	return sc
}

// ── machine info ────────────────────────────────────────────────────────────

func benchGetMachineInfo() benchMachineInfo {
	hostname, _ := os.Hostname()
	return benchMachineInfo{
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		CPUs:     runtime.NumCPU(),
		MemoryGB: benchGetMemoryGB(),
		Hostname: hostname,
	}
}

func benchGetMemoryGB() int {
	switch runtime.GOOS {
	case "linux":
		f, err := os.Open("/proc/meminfo")
		if err != nil {
			return 0
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "MemTotal:") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					kb, err := strconv.ParseInt(fields[1], 10, 64)
					if err == nil {
						return int(kb / (1024 * 1024))
					}
				}
			}
		}
	case "darwin":
		out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
		if err == nil {
			b, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
			if err == nil {
				return int(b / (1024 * 1024 * 1024))
			}
		}
	}
	return 0
}

func benchGitCommit() string {
	out, err := exec.Command("git", "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}
