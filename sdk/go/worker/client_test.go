package worker

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"golang.org/x/net/http2"

	"github.com/user/corvo/internal/raft"
	"github.com/user/corvo/internal/server"
	"github.com/user/corvo/internal/store"
)

func TestDefaultHTTPClientNoTimeout(t *testing.T) {
	c := defaultHTTPClient()
	if c == nil {
		t.Fatal("defaultHTTPClient returned nil")
	}
	if c.Timeout != 0 {
		t.Fatalf("timeout = %s, want 0", c.Timeout)
	}
	tr, ok := c.Transport.(*http2.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http2.Transport", c.Transport)
	}
	if tr.ReadIdleTimeout <= 0 {
		t.Fatalf("read idle timeout = %s, want > 0", tr.ReadIdleTimeout)
	}
	if tr.PingTimeout <= 0 {
		t.Fatalf("ping timeout = %s, want > 0", tr.PingTimeout)
	}
}

func testWorkerClient(t *testing.T, opts ...Option) (*Client, *store.Store) {
	t.Helper()

	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { s.Close() })

	srv := server.New(s, nil, ":0", nil)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	return New(ts.URL, opts...), s
}

func TestLifecycle(t *testing.T) {
	c, s := testWorkerClient(t)
	ctx := context.Background()

	enq, err := c.Enqueue(ctx, EnqueueRequest{
		Queue:   "wc.q",
		Payload: json.RawMessage(`{"hello":"workerclient"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	if enq.JobID == "" {
		t.Fatal("empty job_id")
	}

	job, err := c.Fetch(ctx, FetchRequest{
		Queues:        []string{"wc.q"},
		WorkerID:      "w1",
		Hostname:      "h1",
		LeaseDuration: 10,
	})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if job == nil {
		t.Fatal("expected fetched job")
	}
	if job.JobID != enq.JobID {
		t.Fatalf("job_id = %s, want %s", job.JobID, enq.JobID)
	}

	if err := c.Ack(ctx, job.JobID, json.RawMessage(`{"ok":true}`)); err != nil {
		t.Fatalf("Ack: %v", err)
	}

	got, err := s.GetJob(job.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if got.State != store.StateCompleted {
		t.Fatalf("state = %s, want completed", got.State)
	}
}

func TestProtoJSONMode(t *testing.T) {
	c, _ := testWorkerClient(t, WithProtoJSON())
	ctx := context.Background()

	enq, err := c.Enqueue(ctx, EnqueueRequest{
		Queue:   "wc.json",
		Payload: json.RawMessage(`{"mode":"json"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue with protojson: %v", err)
	}
	if enq.JobID == "" {
		t.Fatal("empty job_id")
	}
}

func TestHeartbeat(t *testing.T) {
	c, _ := testWorkerClient(t)
	ctx := context.Background()

	enq, err := c.Enqueue(ctx, EnqueueRequest{
		Queue:   "wc.hb",
		Payload: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	job, err := c.Fetch(ctx, FetchRequest{
		Queues:   []string{"wc.hb"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if job == nil {
		t.Fatal("expected fetched job")
	}

	statuses, err := c.Heartbeat(ctx, map[string]HeartbeatJobUpdate{
		enq.JobID: {
			Progress: map[string]any{"current": 1, "total": 10},
		},
	})
	if err != nil {
		t.Fatalf("Heartbeat: %v", err)
	}
	if statuses[enq.JobID] == "" {
		t.Fatalf("missing heartbeat status for %s", enq.JobID)
	}
}

func TestAckBatch(t *testing.T) {
	c, s := testWorkerClient(t)
	ctx := context.Background()

	jobs := make([]*FetchedJob, 0, 2)
	for i := 0; i < 2; i++ {
		enq, err := c.Enqueue(ctx, EnqueueRequest{
			Queue:   "wc.ackbatch",
			Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			t.Fatalf("Enqueue: %v", err)
		}
		job, err := c.Fetch(ctx, FetchRequest{
			Queues:   []string{"wc.ackbatch"},
			WorkerID: "w1",
			Hostname: "h1",
		})
		if err != nil {
			t.Fatalf("Fetch: %v", err)
		}
		if job == nil || job.JobID != enq.JobID {
			t.Fatalf("unexpected fetched job")
		}
		jobs = append(jobs, job)
	}

	acked, err := c.AckBatch(ctx, []AckBatchItem{
		{JobID: jobs[0].JobID, Result: json.RawMessage(`{"ok":true}`)},
		{JobID: jobs[1].JobID, Result: json.RawMessage(`{"ok":true}`)},
	})
	if err != nil {
		t.Fatalf("AckBatch: %v", err)
	}
	if acked != 2 {
		t.Fatalf("acked = %d, want 2", acked)
	}

	for _, job := range jobs {
		got, err := s.GetJob(job.JobID)
		if err != nil {
			t.Fatalf("GetJob: %v", err)
		}
		if got.State != store.StateCompleted {
			t.Fatalf("state = %s, want completed", got.State)
		}
	}
}

func TestFetchBatch(t *testing.T) {
	c, _ := testWorkerClient(t)
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		_, err := c.Enqueue(ctx, EnqueueRequest{
			Queue:   "wc.fetchbatch",
			Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			t.Fatalf("Enqueue: %v", err)
		}
	}

	jobs, err := c.FetchBatch(ctx, FetchRequest{
		Queues:   []string{"wc.fetchbatch"},
		WorkerID: "w1",
		Hostname: "h1",
	}, 3)
	if err != nil {
		t.Fatalf("FetchBatch: %v", err)
	}
	if len(jobs) != 3 {
		t.Fatalf("jobs = %d, want 3", len(jobs))
	}
}

func TestLifecycleStream(t *testing.T) {
	c, s := testWorkerClient(t)
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		_, err := c.Enqueue(ctx, EnqueueRequest{
			Queue:   "wc.stream",
			Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			t.Fatalf("Enqueue: %v", err)
		}
	}

	stream := c.OpenLifecycleStream(ctx)
	t.Cleanup(func() { _ = stream.Close() })

	resp, err := stream.Exchange(LifecycleRequest{
		RequestID: 1,
		Enqueues: []LifecycleEnqueueItem{
			{Queue: "wc.stream", Payload: json.RawMessage(`{}`)},
			{Queue: "wc.stream", Payload: json.RawMessage(`{}`)},
			{Queue: "wc.stream", Payload: json.RawMessage(`{}`)},
		},
	})
	if err != nil {
		t.Fatalf("stream enqueue exchange: %v", err)
	}
	if len(resp.EnqueuedJobIDs) != 3 {
		t.Fatalf("enqueued ids = %d, want 3", len(resp.EnqueuedJobIDs))
	}

	resp2, err := stream.Exchange(LifecycleRequest{
		RequestID:    2,
		Queues:       []string{"wc.stream"},
		WorkerID:     "ws1",
		Hostname:     "h1",
		LeaseSeconds: 10,
		FetchCount:   3,
	})
	if err != nil {
		t.Fatalf("stream fetch exchange: %v", err)
	}
	if len(resp2.Jobs) != 3 {
		t.Fatalf("fetched jobs = %d, want 3", len(resp2.Jobs))
	}

	acks := make([]AckBatchItem, 0, len(resp2.Jobs))
	for _, j := range resp2.Jobs {
		acks = append(acks, AckBatchItem{JobID: j.JobID, Result: json.RawMessage(`{"ok":true}`)})
	}

	resp3, err := stream.Exchange(LifecycleRequest{
		RequestID:    3,
		Queues:       []string{"wc.stream"},
		WorkerID:     "ws1",
		Hostname:     "h1",
		LeaseSeconds: 10,
		Acks:         acks,
	})
	if err != nil {
		t.Fatalf("stream ack exchange: %v", err)
	}
	if resp3.Acked != 3 {
		t.Fatalf("acked = %d, want 3", resp3.Acked)
	}

	for _, j := range resp2.Jobs {
		got, err := s.GetJob(j.JobID)
		if err != nil {
			t.Fatalf("GetJob: %v", err)
		}
		if got.State != store.StateCompleted {
			t.Fatalf("job %s state = %s, want completed", j.JobID, got.State)
		}
	}
}
