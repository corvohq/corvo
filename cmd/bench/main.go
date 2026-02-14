package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/user/corvo/pkg/client"
	"github.com/user/corvo/pkg/workerclient"
)

const streamsPerRPCClient = 200

type benchResult struct {
	lats    []time.Duration
	elapsed time.Duration
}

type runSummary struct {
	opsPerSec float64
	avg       time.Duration
	p50       time.Duration
	p90       time.Duration
	p99       time.Duration
	min       time.Duration
	max       time.Duration
	completed int
}

func main() {
	server := flag.String("server", "http://localhost:8080", "server URL")
	protocol := flag.String("protocol", "rpc", "benchmark transport: rpc, http, or matrix")
	jobs := flag.Int("jobs", 10000, "total number of jobs to process")
	concurrency := flag.Int("concurrency", 10, "number of concurrent goroutines")
	workers := flag.Int("workers", 1, "number of logical workers for lifecycle benchmark (total lifecycle streams = workers * concurrency)")
	workerQueues := flag.Bool("worker-queues", false, "use a distinct queue per worker for enqueue+lifecycle benchmarks")
	repeats := flag.Int("repeats", 1, "number of benchmark repeats per protocol")
	repeatPause := flag.Duration("repeat-pause", 0, "pause between repeats (e.g. 500ms)")
	queue := flag.String("queue", "bench.q", "queue name")
	enqueueBatchSize := flag.Int("enqueue-batch-size", 64, "number of jobs to enqueue per stream frame")
	fetchBatchSize := flag.Int("fetch-batch-size", 8, "number of jobs to fetch per request in lifecycle benchmark")
	ackBatchSize := flag.Int("ack-batch-size", 64, "number of ACKs to send per batch in lifecycle benchmark")
	workDuration := flag.Duration("work-duration", 0, "simulated per-job work duration in lifecycle benchmark (e.g. 1ms)")
	flag.Parse()

	fmt.Printf("Corvo Benchmark\n")
	fmt.Printf("  server:      %s\n", *server)
	fmt.Printf("  protocol:    %s\n", *protocol)
	fmt.Printf("  jobs:        %d\n", *jobs)
	fmt.Printf("  concurrency: %d\n", *concurrency)
	fmt.Printf("  workers:     %d\n", *workers)
	fmt.Printf("  worker-queues: %t\n", *workerQueues)
	fmt.Printf("  repeats:     %d\n", *repeats)
	fmt.Printf("  queue:       %s\n\n", *queue)
	fmt.Printf("  enqueue-batch: %d\n", *enqueueBatchSize)
	fmt.Printf("  fetch-batch: %d\n", *fetchBatchSize)
	fmt.Printf("  ack-batch:   %d\n", *ackBatchSize)
	fmt.Printf("  work:        %s\n\n", workDuration.String())

	httpC := &http.Client{Timeout: 30 * time.Second}

	// Health check via HTTP
	resp, err := httpC.Get(*server + "/healthz")
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot reach server: %v\n", err)
		os.Exit(1)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "server unhealthy: status %d\n", resp.StatusCode)
		os.Exit(1)
	}

	run := func(mode string) {
		if *protocol == "matrix" {
			fmt.Printf("\n=== Protocol: %s ===\n", mode)
		}
		enqRuns := make([]runSummary, 0, *repeats)
		lcRuns := make([]runSummary, 0, *repeats)
		for i := 1; i <= *repeats; i++ {
			clearBenchQueues(httpC, *server, *queue, *workers, *workerQueues)
			if *repeats > 1 {
				fmt.Printf("\n-- Run %d/%d --\n", i, *repeats)
			}
			fmt.Println("=== Enqueue Benchmark ===")
			enqResult := benchEnqueue(mode, *server, *jobs, *concurrency, *workers, *queue, *enqueueBatchSize, *workerQueues)
			enqRuns = append(enqRuns, printStats(enqResult))

			fmt.Println("\n=== Processing Benchmark (fetch -> ack) ===")
			lcResult := benchLifecycle(mode, httpC, *server, *jobs, *workers, *concurrency, *queue, *fetchBatchSize, *ackBatchSize, *workDuration, *workerQueues)
			lcRuns = append(lcRuns, printStats(lcResult))

			if i < *repeats && *repeatPause > 0 {
				time.Sleep(*repeatPause)
			}
		}
		if *repeats > 1 {
			fmt.Println("\n=== Repeat Summary: Enqueue ===")
			printRunAggregate(enqRuns)
			fmt.Println("\n=== Repeat Summary: Lifecycle ===")
			printRunAggregate(lcRuns)
		}
	}

	switch *protocol {
	case "rpc", "http":
		run(*protocol)
	case "matrix":
		run("rpc")
		run("http")
	default:
		fmt.Fprintf(os.Stderr, "invalid -protocol %q (expected rpc, http, matrix)\n", *protocol)
		os.Exit(2)
	}
}

func benchEnqueue(protocol, serverURL string, total, concurrency, workers int, queue string, enqueueBatchSize int, workerQueues bool) benchResult {
	if enqueueBatchSize <= 0 {
		enqueueBatchSize = 1
	}
	lats := make([]time.Duration, total)
	var idx atomic.Int64
	var queueRR atomic.Int64
	var overloads atomic.Int64
	var wg sync.WaitGroup
	var rpcClients []*workerclient.Client
	if protocol != "http" {
		rpcClients = newRPCClientPool(serverURL, concurrency)
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
		go func(count int, workerID string) {
			defer wg.Done()
			if protocol == "http" && enqueueBatchSize == 1 {
				c := client.New(serverURL)
				for range count {
					targetQueue := queue
					if workerQueues {
						targetQueue = workerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
					}
					opStart := time.Now()
					_, err := c.Enqueue(targetQueue, map[string]any{})
					if err != nil {
						if isOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(overloadBackoff(overloads.Load()))
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
							targetQueue = workerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
						}
						jobs = append(jobs, client.BatchJob{Queue: targetQueue, Payload: map[string]any{}})
					}
					opStart := time.Now()
					resp, err := c.EnqueueBatch(client.BatchRequest{Jobs: jobs})
					if err != nil {
						if isOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(overloadBackoff(overloads.Load()))
							continue
						}
						fmt.Fprintf(os.Stderr, "enqueue batch error: %v\n", err)
						continue
					}
					lat := time.Since(opStart)
					for range resp.JobIDs {
						pos := idx.Add(1) - 1
						if pos >= int64(total) {
							break
						}
						lats[pos] = lat
						remaining--
					}
				}
				return
			}

			wc := rpcClients[i%len(rpcClients)]
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
				enqueues := make([]workerclient.LifecycleEnqueueItem, 0, n)
				for range n {
					targetQueue := queue
					if workerQueues {
						targetQueue = workerQueueName(queue, workers, int(queueRR.Add(1)-1)%max(workers, 1))
					}
					enqueues = append(enqueues, workerclient.LifecycleEnqueueItem{
						Queue:   targetQueue,
						Payload: json.RawMessage(`{}`),
					})
				}
				opStart := time.Now()
				resp, err := stream.Exchange(workerclient.LifecycleRequest{
					RequestID: reqID,
					Enqueues:  enqueues,
				})
				reqID++
				if err != nil {
					if isOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(overloadBackoff(overloads.Load()))
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
					if isOverloadMsg(resp.Error) {
						overloads.Add(1)
						time.Sleep(overloadBackoff(overloads.Load()))
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
		}(n, fmt.Sprintf("enq-worker-%d", i))
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

func benchLifecycle(protocol string, httpC *http.Client, serverURL string, total, workers, concurrency int, queue string, fetchBatchSize, ackBatchSize int, workDuration time.Duration, workerQueues bool) benchResult {
	// This benchmark measures worker processing latency and throughput:
	// fetch -> optional work-duration sleep -> ack.
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
	var rpcClients []*workerclient.Client
	if protocol != "http" {
		rpcClients = newRPCClientPool(serverURL, workers*concurrency)
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
			workerQueue = workerQueueName(queue, workers, workerIdx)
		}
		wg.Add(1)
		go func(count int, wid, wq string) {
			defer wg.Done()
			if protocol == "http" {
				remaining := count
				pending := make([]fetchedItem, 0, ackBatchSize*2)
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
						if err := ackJobs(httpC, serverURL, ids); err != nil {
							if isOverloadErr(err) {
								overloads.Add(1)
								time.Sleep(overloadBackoff(overloads.Load()))
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
					fetched, err := fetchJobs(httpC, serverURL, wq, wid, fetchN)
					if err != nil {
						if isOverloadErr(err) {
							overloads.Add(1)
							time.Sleep(overloadBackoff(overloads.Load()))
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
			wc := rpcClients[i%len(rpcClients)]
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
				acks := make([]workerclient.AckBatchItem, 0, ackN)
				for _, id := range ackIDs {
					acks = append(acks, workerclient.AckBatchItem{
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
				resp, err := stream.Exchange(workerclient.LifecycleRequest{
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
					if isOverloadErr(err) {
						overloads.Add(1)
						time.Sleep(overloadBackoff(overloads.Load()))
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
					if isOverloadMsg(resp.Error) {
						overloads.Add(1)
					} else {
						streamErrs++
						if streamErrs <= 3 || streamErrs%1000 == 0 {
							fmt.Fprintf(os.Stderr, "lifecycle stream frame error: %s\n", resp.Error)
						}
					}
					// Backoff on ALL errors to avoid amplification.
					// ACK IDs stay in pendingOrder for retry after delay.
					time.Sleep(overloadBackoff(overloads.Load()))
				}

				acked := resp.Acked
				if acked > len(ackIDs) {
					acked = len(ackIDs)
				}
				now := time.Now()
				for i := 0; i < acked; i++ {
					id := ackIDs[i]
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

				// If some ACKs are repeatedly skipped with no frame error,
				// treat them as stale and drop them so the benchmark can
				// re-fetch the underlying jobs instead of deadlocking.
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
		}(n, workerID, workerQueue)
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

func fetchJob(httpC *http.Client, serverURL, queue, workerID string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"queues":    []string{queue},
		"worker_id": workerID,
		"hostname":  "bench-host",
		"timeout":   1,
	})
	resp, err := httpC.Post(serverURL+"/api/v1/fetch", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("fetch request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNoContent {
		return "", fmt.Errorf("no jobs available")
	}
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("fetch status %d: %s", resp.StatusCode, data)
	}

	var result struct {
		JobID string `json:"job_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("fetch decode: %w", err)
	}
	return result.JobID, nil
}

type fetchedItem struct {
	jobID   string
	started time.Time
}

func fetchJobs(httpC *http.Client, serverURL, queue, workerID string, count int) ([]fetchedItem, error) {
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

	items := make([]fetchedItem, 0, len(result.Jobs))
	for _, j := range result.Jobs {
		if j.JobID == "" {
			continue
		}
		items = append(items, fetchedItem{jobID: j.JobID, started: opStart})
	}
	return items, nil
}

func ackJob(httpC *http.Client, serverURL, jobID string) error {
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

func ackJobs(httpC *http.Client, serverURL string, jobIDs []string) error {
	if len(jobIDs) == 1 {
		return ackJob(httpC, serverURL, jobIDs[0])
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

func clearQueue(httpC *http.Client, serverURL, queue string) {
	req, _ := http.NewRequest("POST", serverURL+"/api/v1/queues/"+queue+"/clear", nil)
	resp, err := httpC.Do(req)
	if err != nil {
		return // queue may not exist yet
	}
	resp.Body.Close()
}

func clearBenchQueues(httpC *http.Client, serverURL, baseQueue string, workers int, workerQueues bool) {
	if !workerQueues || workers <= 1 {
		clearQueue(httpC, serverURL, baseQueue)
		return
	}
	for i := 0; i < workers; i++ {
		clearQueue(httpC, serverURL, workerQueueName(baseQueue, workers, i))
	}
}

func workerQueueName(base string, workers, idx int) string {
	if workers <= 1 {
		return base
	}
	return fmt.Sprintf("%s.w%d", base, idx)
}

func newRPCClientPool(serverURL string, totalStreams int) []*workerclient.Client {
	if totalStreams <= 0 {
		totalStreams = 1
	}
	n := (totalStreams + streamsPerRPCClient - 1) / streamsPerRPCClient
	if n < 1 {
		n = 1
	}
	clients := make([]*workerclient.Client, 0, n)
	for range n {
		clients = append(clients, workerclient.New(serverURL))
	}
	return clients
}

func summarize(r benchResult) runSummary {
	if len(r.lats) == 0 {
		return runSummary{}
	}
	slices.Sort(r.lats)

	n := len(r.lats)
	opsPerSec := float64(n) / r.elapsed.Seconds()

	var sum time.Duration
	for _, l := range r.lats {
		sum += l
	}
	avg := sum / time.Duration(n)

	return runSummary{
		opsPerSec: opsPerSec,
		avg:       avg,
		p50:       r.lats[n*50/100],
		p90:       r.lats[n*90/100],
		p99:       r.lats[n*99/100],
		min:       r.lats[0],
		max:       r.lats[n-1],
		completed: n,
	}
}

func printStats(r benchResult) runSummary {
	if len(r.lats) == 0 {
		fmt.Println("  no successful operations")
		return runSummary{}
	}

	s := summarize(r)
	fmt.Printf("  ops/sec: %.1f\n", s.opsPerSec)
	fmt.Printf("  avg:     %s\n", s.avg.Round(time.Microsecond))
	fmt.Printf("  p50:     %s\n", s.p50.Round(time.Microsecond))
	fmt.Printf("  p90:     %s\n", s.p90.Round(time.Microsecond))
	fmt.Printf("  p99:     %s\n", s.p99.Round(time.Microsecond))
	fmt.Printf("  min:     %s\n", s.min.Round(time.Microsecond))
	fmt.Printf("  max:     %s\n", s.max.Round(time.Microsecond))
	return s
}

func printRunAggregate(runs []runSummary) {
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
	p90Ops := opsVals[percentileIndex(len(opsVals), 90)]
	medianP99 := p99Vals[len(p99Vals)/2]
	p90P99 := p99Vals[percentileIndex(len(p99Vals), 90)]
	fmt.Printf("  ops/sec median: %.1f\n", medianOps)
	fmt.Printf("  ops/sec p90:    %.1f\n", p90Ops)
	fmt.Printf("  p99 median:     %s\n", medianP99.Round(time.Microsecond))
	fmt.Printf("  p99 p90:        %s\n", p90P99.Round(time.Microsecond))
}

func percentileIndex(n, p int) int {
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

func isOverloadErr(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToUpper(err.Error())
	return strings.Contains(s, "OVERLOADED") ||
		strings.Contains(s, "RESOURCE_EXHAUSTED") ||
		strings.Contains(s, "429")
}

func isOverloadMsg(msg string) bool {
	s := strings.ToUpper(msg)
	return strings.Contains(s, "OVERLOADED") || strings.Contains(s, "429")
}

func overloadBackoff(attempt int64) time.Duration {
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
