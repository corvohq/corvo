package server

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"connectrpc.com/connect"
	"github.com/user/jobbie/internal/raft"
	jobbiev1 "github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1"
	"github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1/jobbiev1connect"
	"github.com/user/jobbie/internal/store"
	"golang.org/x/net/http2"
)

type mockCluster struct {
	isLeader   bool
	leaderAddr string
}

func (m mockCluster) IsLeader() bool     { return m.isLeader }
func (m mockCluster) LeaderAddr() string { return m.leaderAddr }
func (m mockCluster) ClusterStatus() map[string]any {
	return map[string]any{
		"mode":          "cluster",
		"sqlite_mirror": map[string]any{"enabled": true},
		"sqlite_rebuild": map[string]any{
			"ran": false,
		},
	}
}
func (m mockCluster) State() string                  { return "follower" }
func (m mockCluster) RebuildSQLiteFromPebble() error { return nil }
func (m mockCluster) EventLog(afterSeq uint64, limit int) ([]map[string]any, error) {
	return []map[string]any{{"seq": 1, "type": "enqueued"}}, nil
}

func testServer(t *testing.T) (*Server, *store.Store) {
	t.Helper()
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { s.Close() })
	srv := New(s, nil, ":0", nil)
	return srv, s
}

func doRequest(srv *Server, method, path string, body interface{}) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)
	return rr
}

func decodeResponse(t *testing.T, rr *httptest.ResponseRecorder, v interface{}) {
	t.Helper()
	if err := json.NewDecoder(rr.Body).Decode(v); err != nil {
		t.Fatalf("decode response: %v (body: %s)", err, rr.Body.String())
	}
}

func TestHealthz(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "GET", "/healthz", nil)
	if rr.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rr.Code, http.StatusOK)
	}
}

func TestRebuildSQLiteEndpointCluster(t *testing.T) {
	_, s := testServer(t)
	srv := New(s, mockCluster{isLeader: true}, ":0", nil)
	rr := doRequest(srv, "POST", "/api/v1/admin/rebuild-sqlite", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var body map[string]any
	decodeResponse(t, rr, &body)
	if body["status"] != "ok" {
		t.Fatalf("status body = %v", body["status"])
	}
}

func TestClusterStatusIncludesSQLiteStats(t *testing.T) {
	_, s := testServer(t)
	srv := New(s, mockCluster{isLeader: true}, ":0", nil)
	rr := doRequest(srv, "GET", "/api/v1/cluster/status", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var body map[string]any
	decodeResponse(t, rr, &body)
	if _, ok := body["sqlite_mirror"]; !ok {
		t.Fatalf("missing sqlite_mirror in cluster status")
	}
	if _, ok := body["sqlite_rebuild"]; !ok {
		t.Fatalf("missing sqlite_rebuild in cluster status")
	}
}

func TestEnqueueEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue":   "test.queue",
		"payload": map[string]string{"hello": "world"},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d, body: %s", rr.Code, http.StatusCreated, rr.Body.String())
	}

	var result store.EnqueueResult
	decodeResponse(t, rr, &result)
	if result.JobID == "" {
		t.Error("job_id is empty")
	}
}

func TestEnqueueEndpointUniqueFallback(t *testing.T) {
	srv, _ := testServer(t)
	req := map[string]any{
		"queue":         "unique.q",
		"payload":       map[string]string{"hello": "world"},
		"unique_key":    "u-1",
		"unique_period": 60,
	}

	first := doRequest(srv, "POST", "/api/v1/enqueue", req)
	if first.Code != http.StatusCreated {
		t.Fatalf("first status = %d, body: %s", first.Code, first.Body.String())
	}
	var firstResult store.EnqueueResult
	decodeResponse(t, first, &firstResult)
	if firstResult.UniqueExisting {
		t.Fatalf("first enqueue unexpectedly marked unique_existing")
	}

	second := doRequest(srv, "POST", "/api/v1/enqueue", req)
	if second.Code != http.StatusOK {
		t.Fatalf("second status = %d, body: %s", second.Code, second.Body.String())
	}
	var secondResult store.EnqueueResult
	decodeResponse(t, second, &secondResult)
	if !secondResult.UniqueExisting {
		t.Fatalf("second enqueue should be unique_existing")
	}
	if secondResult.JobID != firstResult.JobID {
		t.Fatalf("unique duplicate job_id mismatch: got %s want %s", secondResult.JobID, firstResult.JobID)
	}
}

func TestEnqueueValidation(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"payload": map[string]string{"hello": "world"},
	})
	if rr.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", rr.Code, http.StatusBadRequest)
	}
}

func TestEnqueueBatchEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/enqueue/batch", map[string]interface{}{
		"jobs": []map[string]interface{}{
			{"queue": "batch.q", "payload": map[string]int{"i": 1}},
			{"queue": "batch.q", "payload": map[string]int{"i": 2}},
		},
		"batch": map[string]interface{}{
			"callback_queue": "batch.done",
		},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var result store.BatchEnqueueResult
	decodeResponse(t, rr, &result)
	if len(result.JobIDs) != 2 {
		t.Errorf("job_ids count = %d, want 2", len(result.JobIDs))
	}
}

func TestFetchAndAckEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	// Enqueue
	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue":   "fetch.q",
		"payload": map[string]string{"task": "do-it"},
	})

	// Fetch (with short timeout so it doesn't long-poll forever)
	rr := doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues":    []string{"fetch.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fetch status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var fetchResult store.FetchResult
	decodeResponse(t, rr, &fetchResult)

	// Ack
	rr = doRequest(srv, "POST", "/api/v1/ack/"+fetchResult.JobID, map[string]interface{}{
		"result": map[string]bool{"done": true},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack status = %d, body: %s", rr.Code, rr.Body.String())
	}
}

func TestFetchBatchEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	for i := 0; i < 2; i++ {
		doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
			"queue":   "fetch-batch.q",
			"payload": map[string]int{"i": i},
		})
	}

	rr := doRequest(srv, "POST", "/api/v1/fetch/batch", map[string]interface{}{
		"queues":    []string{"fetch-batch.q"},
		"worker_id": "wb",
		"hostname":  "h1",
		"timeout":   1,
		"count":     2,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fetch batch status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var out struct {
		Jobs []store.FetchResult `json:"jobs"`
	}
	decodeResponse(t, rr, &out)
	if len(out.Jobs) != 2 {
		t.Fatalf("jobs = %d, want 2", len(out.Jobs))
	}
}

func TestAckBatchEndpoint(t *testing.T) {
	srv, s := testServer(t)

	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue":   "ack-batch.q",
		"payload": map[string]string{"i": "1"},
	})
	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue":   "ack-batch.q",
		"payload": map[string]string{"i": "2"},
	})

	rr := doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues":    []string{"ack-batch.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	var job1 store.FetchResult
	decodeResponse(t, rr, &job1)

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues":    []string{"ack-batch.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	var job2 store.FetchResult
	decodeResponse(t, rr, &job2)

	rr = doRequest(srv, "POST", "/api/v1/ack/batch", map[string]interface{}{
		"acks": []map[string]interface{}{
			{"job_id": job1.JobID, "result": map[string]bool{"ok": true}},
			{"job_id": job2.JobID, "result": map[string]bool{"ok": true}},
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack batch status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var resp struct {
		Acked int `json:"acked"`
	}
	decodeResponse(t, rr, &resp)
	if resp.Acked != 2 {
		t.Fatalf("acked = %d, want 2", resp.Acked)
	}

	j1, err := s.GetJob(job1.JobID)
	if err != nil {
		t.Fatalf("get job1: %v", err)
	}
	if j1.State != store.StateCompleted {
		t.Fatalf("job1 state = %s, want %s", j1.State, store.StateCompleted)
	}
	j2, err := s.GetJob(job2.JobID)
	if err != nil {
		t.Fatalf("get job2: %v", err)
	}
	if j2.State != store.StateCompleted {
		t.Fatalf("job2 state = %s, want %s", j2.State, store.StateCompleted)
	}
}

func TestFailEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "fail.q", "payload": map[string]string{},
	})
	rr := doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues": []string{"fail.q"}, "worker_id": "w", "hostname": "h", "timeout": 1,
	})
	var fetchResult store.FetchResult
	decodeResponse(t, rr, &fetchResult)

	rr = doRequest(srv, "POST", "/api/v1/fail/"+fetchResult.JobID, map[string]interface{}{
		"error":     "something broke",
		"backtrace": "at line 42",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fail status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var failResult store.FailResult
	decodeResponse(t, rr, &failResult)
	if failResult.Status != "retrying" && failResult.Status != "dead" {
		t.Errorf("fail status = %q", failResult.Status)
	}
}

func TestQueueEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	// Create queue by enqueuing
	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "mgmt.q", "payload": map[string]string{},
	})

	// List queues
	rr := doRequest(srv, "GET", "/api/v1/queues", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list queues status = %d", rr.Code)
	}

	// Pause
	rr = doRequest(srv, "POST", "/api/v1/queues/mgmt.q/pause", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("pause status = %d, body: %s", rr.Code, rr.Body.String())
	}

	// Resume
	rr = doRequest(srv, "POST", "/api/v1/queues/mgmt.q/resume", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("resume status = %d, body: %s", rr.Code, rr.Body.String())
	}
}

func TestJobEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	// Enqueue
	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "job.q", "payload": map[string]string{"k": "v"},
	})
	var enqResult store.EnqueueResult
	decodeResponse(t, rr, &enqResult)

	// Get job
	rr = doRequest(srv, "GET", "/api/v1/jobs/"+enqResult.JobID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get job status = %d, body: %s", rr.Code, rr.Body.String())
	}

	// Cancel job
	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/cancel", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("cancel status = %d, body: %s", rr.Code, rr.Body.String())
	}

	// Get job not found
	rr = doRequest(srv, "GET", "/api/v1/jobs/nonexistent", nil)
	if rr.Code != http.StatusNotFound {
		t.Errorf("get nonexistent status = %d, want 404", rr.Code)
	}
}

func TestHeldJobEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "held.q", "payload": map[string]string{"k": "v"},
	})
	var enqResult store.EnqueueResult
	decodeResponse(t, rr, &enqResult)

	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/hold", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("hold status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/approve", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("approve status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/hold", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("hold(2) status = %d, body: %s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/reject", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("reject status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/jobs/"+enqResult.JobID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get job status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var job store.Job
	decodeResponse(t, rr, &job)
	if job.State != store.StateDead {
		t.Fatalf("job state = %s, want %s", job.State, store.StateDead)
	}
}

func TestReplayEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "replay.q",
		"payload": map[string]string{"k": "v"},
		"agent": map[string]any{
			"max_iterations": 5,
			"max_cost_usd":   10.0,
		},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var enqResult store.EnqueueResult
	decodeResponse(t, rr, &enqResult)

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{"replay.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fetch status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var f1 store.FetchResult
	decodeResponse(t, rr, &f1)

	rr = doRequest(srv, "POST", "/api/v1/ack/"+f1.JobID, map[string]any{
		"agent_status": "continue",
		"checkpoint":   map[string]any{"cursor": "iter1"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack continue status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/jobs/"+enqResult.JobID+"/replay", map[string]any{
		"from": 1,
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("replay status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var replay store.EnqueueResult
	decodeResponse(t, rr, &replay)
	if replay.JobID == "" {
		t.Fatal("replay job_id is empty")
	}

	rr = doRequest(srv, "GET", "/api/v1/jobs/"+replay.JobID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get replayed job status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var replayedJob store.Job
	decodeResponse(t, rr, &replayedJob)
	if string(replayedJob.Checkpoint) != `{"cursor":"iter1"}` {
		t.Fatalf("replayed checkpoint = %s", string(replayedJob.Checkpoint))
	}
}

func TestSearchEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "search.q", "payload": map[string]string{},
	})

	rr := doRequest(srv, "POST", "/api/v1/jobs/search", map[string]interface{}{
		"queue": "search.q",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("search status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var result store.SearchResult
	decodeResponse(t, rr, &result)
	if result.Total != 1 {
		t.Errorf("search total = %d, want 1", result.Total)
	}
}

func TestBulkEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	var ids []string
	for range 3 {
		rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
			"queue": "bulk.q", "payload": map[string]string{},
		})
		var r store.EnqueueResult
		decodeResponse(t, rr, &r)
		ids = append(ids, r.JobID)
	}

	rr := doRequest(srv, "POST", "/api/v1/jobs/bulk", map[string]interface{}{
		"job_ids": ids,
		"action":  "cancel",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("bulk status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var result store.BulkResult
	decodeResponse(t, rr, &result)
	if result.Affected != 3 {
		t.Errorf("affected = %d, want 3", result.Affected)
	}
}

func TestBudgetEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/budgets", map[string]any{
		"scope":       "queue",
		"target":      "budget.api",
		"daily_usd":   5.0,
		"per_job_usd": 1.0,
		"on_exceed":   "hold",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set budget status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/budgets", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list budgets status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var budgets []map[string]any
	decodeResponse(t, rr, &budgets)
	if len(budgets) == 0 {
		t.Fatalf("expected at least one budget")
	}

	rr = doRequest(srv, "DELETE", "/api/v1/budgets/queue/budget.api", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete budget status = %d, body: %s", rr.Code, rr.Body.String())
	}
}

func TestClusterStatusEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "GET", "/api/v1/cluster/status", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("cluster status = %d", rr.Code)
	}
}

func TestClusterEventsEndpoint(t *testing.T) {
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })
	s := store.NewStore(da, da.SQLiteDB())
	srv := New(s, mockCluster{isLeader: true}, ":0", nil)
	rr := doRequest(srv, "GET", "/api/v1/cluster/events?limit=10", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("cluster events status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var out struct {
		Events []map[string]any `json:"events"`
	}
	decodeResponse(t, rr, &out)
	if len(out.Events) == 0 {
		t.Fatalf("expected events")
	}
}

func TestWorkersEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "GET", "/api/v1/workers", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("workers status = %d", rr.Code)
	}
}

func TestCORSHeaders(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "OPTIONS", "/api/v1/enqueue", nil)
	if rr.Code != http.StatusOK {
		t.Errorf("OPTIONS status = %d, want 200", rr.Code)
	}
	if rr.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Error("missing CORS header")
	}
}

func TestWriteProxyToLeader(t *testing.T) {
	leaderSrv, leaderStore := testServer(t)
	leaderTS := httptest.NewServer(leaderSrv.Handler())
	defer leaderTS.Close()

	leaderURL, err := url.Parse(leaderTS.URL)
	if err != nil {
		t.Fatalf("parse leader URL: %v", err)
	}

	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()
	followerStore := store.NewStore(da, da.SQLiteDB())
	defer followerStore.Close()

	followerSrv := New(followerStore, mockCluster{
		isLeader:   false,
		leaderAddr: leaderURL.String(),
	}, ":0", nil)
	followerTS := httptest.NewServer(followerSrv.Handler())
	defer followerTS.Close()

	body, _ := json.Marshal(map[string]any{
		"queue":   "proxy.q",
		"payload": map[string]string{"k": "v"},
	})
	resp, err := http.Post(followerTS.URL+"/api/v1/enqueue", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST enqueue via follower: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d body=%s", resp.StatusCode, string(data))
	}

	var result store.EnqueueResult
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode enqueue response: %v", err)
	}
	if result.JobID == "" {
		t.Fatal("empty job ID")
	}
	if _, err := leaderStore.GetJob(result.JobID); err != nil {
		t.Fatalf("job not created on leader: %v", err)
	}
}

func TestConnectWorkerLifecycle(t *testing.T) {
	srv, s := testServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	client := jobbiev1connect.NewWorkerServiceClient(ts.Client(), ts.URL)

	enqResp, err := client.Enqueue(context.Background(), connect.NewRequest(&jobbiev1.EnqueueRequest{
		Queue:       "connect.q",
		PayloadJson: `{"hello":"connect"}`,
	}))
	if err != nil {
		t.Fatalf("connect enqueue: %v", err)
	}
	jobID := enqResp.Msg.GetJobId()
	if jobID == "" {
		t.Fatal("empty job_id")
	}

	fetchResp, err := client.Fetch(context.Background(), connect.NewRequest(&jobbiev1.FetchRequest{
		Queues:        []string{"connect.q"},
		WorkerId:      "w1",
		Hostname:      "h1",
		LeaseDuration: 10,
	}))
	if err != nil {
		t.Fatalf("connect fetch: %v", err)
	}
	if !fetchResp.Msg.GetFound() {
		t.Fatal("fetch returned not found")
	}
	if fetchResp.Msg.GetJobId() != jobID {
		t.Fatalf("fetched job_id = %s want %s", fetchResp.Msg.GetJobId(), jobID)
	}

	if _, err := client.Ack(context.Background(), connect.NewRequest(&jobbiev1.AckRequest{
		JobId:      jobID,
		ResultJson: `{"ok":true}`,
	})); err != nil {
		t.Fatalf("connect ack: %v", err)
	}

	job, err := s.GetJob(jobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.State != store.StateCompleted {
		t.Fatalf("state = %s want completed", job.State)
	}
}

func TestConnectWorkerLifecycleStream(t *testing.T) {
	srv, s := testServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	tr := &http2.Transport{
		AllowHTTP: true,
		DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		},
	}
	httpClient := &http.Client{Transport: tr}
	client := jobbiev1connect.NewWorkerServiceClient(httpClient, ts.URL)
	if _, err := client.Enqueue(context.Background(), connect.NewRequest(&jobbiev1.EnqueueRequest{
		Queue:       "connect.stream.q",
		PayloadJson: `{}`,
	})); err != nil {
		t.Fatalf("connect enqueue 1: %v", err)
	}
	if _, err := client.Enqueue(context.Background(), connect.NewRequest(&jobbiev1.EnqueueRequest{
		Queue:       "connect.stream.q",
		PayloadJson: `{}`,
	})); err != nil {
		t.Fatalf("connect enqueue 2: %v", err)
	}

	stream := client.StreamLifecycle(context.Background())
	defer stream.CloseRequest()

	if err := stream.Send(&jobbiev1.LifecycleStreamRequest{
		RequestId:     1,
		Queues:        []string{"connect.stream.q"},
		WorkerId:      "w1",
		Hostname:      "h1",
		LeaseDuration: 10,
		FetchCount:    2,
	}); err != nil {
		t.Fatalf("stream send fetch: %v", err)
	}
	fetchResp, err := stream.Receive()
	if err != nil {
		t.Fatalf("stream receive fetch: %v", err)
	}
	if len(fetchResp.GetJobs()) != 2 {
		t.Fatalf("fetched jobs = %d, want 2", len(fetchResp.GetJobs()))
	}

	acks := make([]*jobbiev1.AckBatchItem, 0, 2)
	for _, job := range fetchResp.GetJobs() {
		acks = append(acks, &jobbiev1.AckBatchItem{JobId: job.GetJobId(), ResultJson: `{"ok":true}`})
	}
	if err := stream.Send(&jobbiev1.LifecycleStreamRequest{
		RequestId: 2,
		Acks:      acks,
	}); err != nil {
		t.Fatalf("stream send ack: %v", err)
	}
	ackResp, err := stream.Receive()
	if err != nil {
		t.Fatalf("stream receive ack: %v", err)
	}
	if ackResp.GetAcked() != 2 {
		t.Fatalf("acked = %d, want 2", ackResp.GetAcked())
	}

	for _, job := range fetchResp.GetJobs() {
		got, err := s.GetJob(job.GetJobId())
		if err != nil {
			t.Fatalf("GetJob: %v", err)
		}
		if got.State != store.StateCompleted {
			t.Fatalf("job %s state = %s want completed", job.GetJobId(), got.State)
		}
	}
}
