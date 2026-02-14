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
	"strconv"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/user/corvo/internal/enterprise"
	"github.com/user/corvo/internal/raft"
	corvov1 "github.com/user/corvo/internal/rpcconnect/gen/corvo/v1"
	"github.com/user/corvo/internal/rpcconnect/gen/corvo/v1/corvov1connect"
	"github.com/user/corvo/internal/store"
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

type mockClusterWithVoter struct {
	mockCluster
	addErr error
	added  []string
}

func (m *mockClusterWithVoter) AddVoter(nodeID, addr string) error {
	if m.addErr != nil {
		return m.addErr
	}
	m.added = append(m.added, nodeID+"@"+addr)
	return nil
}

type mockShardCluster struct {
	mockCluster
	addErr       error
	added        []string
	shardCount   int
	localShards  map[int]bool
	shardLeaders map[int]string
}

func (m *mockShardCluster) AddVoterForShard(shard int, nodeID, addr string) error {
	if m.addErr != nil {
		return m.addErr
	}
	m.added = append(m.added, nodeID+"@"+addr+"#"+strconv.Itoa(shard))
	return nil
}

func (m *mockShardCluster) ShardCount() int {
	if m.shardCount <= 0 {
		return 1
	}
	return m.shardCount
}

func (m *mockShardCluster) IsLeaderForShard(shard int) bool {
	return m.localShards[shard]
}

func (m *mockShardCluster) LeaderAddrForShard(shard int) string {
	return m.shardLeaders[shard]
}

func (m *mockShardCluster) ShardForQueue(queue string) int {
	if strings.Contains(queue, "q1") || strings.Contains(queue, "s1") {
		return 1
	}
	return 0
}

func (m *mockShardCluster) ShardForJobID(jobID string) (int, bool) {
	if strings.HasPrefix(jobID, "s01_") {
		return 1, true
	}
	if strings.HasPrefix(jobID, "s00_") {
		return 0, true
	}
	return 0, false
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
	return doRequestWithHeaders(srv, method, path, body, nil)
}

func doRequestWithHeaders(srv *Server, method, path string, body interface{}, headers map[string]string) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
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

func TestRateLimitMiddlewareDeniesBurst(t *testing.T) {
	_, s := testServer(t)
	srv := New(s, nil, ":0", nil, WithRateLimit(RateLimitConfig{
		Enabled:    true,
		ReadRPS:    0.0001,
		ReadBurst:  1,
		WriteRPS:   0.0001,
		WriteBurst: 1,
	}))
	rr := doRequest(srv, "GET", "/api/v1/queues", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("first request status = %d body=%s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/queues", nil)
	if rr.Code != http.StatusTooManyRequests {
		t.Fatalf("second request status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestPrometheusMetricsIncludeHTTPSeries(t *testing.T) {
	srv, _ := testServer(t)
	_ = doRequest(srv, "GET", "/api/v1/queues", nil)
	rr := doRequest(srv, "GET", "/api/v1/metrics", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("metrics status = %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	for _, needle := range []string{
		"corvo_http_requests_total",
		"corvo_http_request_duration_seconds_bucket",
		"corvo_http_requests_in_flight",
	} {
		if !strings.Contains(body, needle) {
			t.Fatalf("metrics missing %q", needle)
		}
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

func TestAPIKeyBearerHeader(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name": "admin",
		"key":  "k_admin_bearer",
		"role": "admin",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("create key status = %d body=%s", rr.Code, rr.Body.String())
	}
	headers := map[string]string{"Authorization": "Bearer k_admin_bearer"}
	rr = doRequestWithHeaders(srv, "GET", "/api/v1/queues", nil, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("queues status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestAPIKeyExpiry(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name":       "expired",
		"key":        "k_expired",
		"role":       "admin",
		"expires_at": time.Now().Add(-time.Hour).UTC().Format(time.RFC3339Nano),
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("create key status = %d body=%s", rr.Code, rr.Body.String())
	}
	headers := map[string]string{"X-API-Key": "k_expired"}
	rr = doRequestWithHeaders(srv, "GET", "/api/v1/queues", nil, headers)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("queues status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestCustomRBACRolePermissions(t *testing.T) {
	_, s := testServer(t)
	lic := &enterprise.License{Features: map[string]struct{}{"rbac": {}}}
	srv := New(s, nil, ":0", nil, WithEnterpriseLicense(lic))

	rr := doRequest(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name": "admin",
		"key":  "k_admin_rbac",
		"role": "admin",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("create admin key status = %d body=%s", rr.Code, rr.Body.String())
	}
	adminHeaders := map[string]string{"X-API-Key": "k_admin_rbac"}

	rr = doRequestWithHeaders(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name": "custom",
		"key":  "k_custom_rbac",
		"role": "custom",
	}, adminHeaders)
	if rr.Code != http.StatusOK {
		t.Fatalf("create custom key status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequestWithHeaders(srv, "POST", "/api/v1/auth/roles", map[string]any{
		"name": "queue-reader",
		"permissions": []map[string]any{
			{"resource": "queues", "actions": []string{"read"}},
		},
	}, adminHeaders)
	if rr.Code != http.StatusOK {
		t.Fatalf("create role status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequestWithHeaders(srv, "POST", "/api/v1/auth/keys/"+hashAPIKey("k_custom_rbac")+"/roles", map[string]any{
		"role": "queue-reader",
	}, adminHeaders)
	if rr.Code != http.StatusOK {
		t.Fatalf("assign role status = %d body=%s", rr.Code, rr.Body.String())
	}

	customHeaders := map[string]string{"X-API-Key": "k_custom_rbac"}
	rr = doRequestWithHeaders(srv, "GET", "/api/v1/queues", nil, customHeaders)
	if rr.Code != http.StatusOK {
		t.Fatalf("custom read status = %d body=%s", rr.Code, rr.Body.String())
	}
	rr = doRequestWithHeaders(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "rbac.q",
		"payload": map[string]any{"ok": true},
	}, customHeaders)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("custom write status = %d body=%s", rr.Code, rr.Body.String())
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

func TestFailEndpointProviderError(t *testing.T) {
	srv, s := testServer(t)

	doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "fail.provider.q", "payload": map[string]string{},
	})
	rr := doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues": []string{"fail.provider.q"}, "worker_id": "w", "hostname": "h", "timeout": 1,
	})
	var fetchResult store.FetchResult
	decodeResponse(t, rr, &fetchResult)

	rr = doRequest(srv, "POST", "/api/v1/fail/"+fetchResult.JobID, map[string]interface{}{
		"error":          "provider timeout",
		"provider_error": true,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fail status = %d, body: %s", rr.Code, rr.Body.String())
	}
	j, err := s.GetJob(fetchResult.JobID)
	if err != nil {
		t.Fatalf("get job: %v", err)
	}
	if !j.ProviderError {
		t.Fatalf("provider_error = false, want true")
	}
}

func TestAckResultSchemaValidation(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue": "schema.q",
		"payload": map[string]interface{}{
			"task": "extract",
		},
		"result_schema": map[string]interface{}{
			"type":     "object",
			"required": []string{"vendor"},
			"properties": map[string]interface{}{
				"vendor": map[string]interface{}{"type": "string"},
			},
		},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var enq store.EnqueueResult
	decodeResponse(t, rr, &enq)

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]interface{}{
		"queues":    []string{"schema.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("fetch status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/ack/"+enq.JobID, map[string]interface{}{
		"result": map[string]interface{}{},
	})
	if rr.Code != http.StatusUnprocessableEntity {
		t.Fatalf("ack status = %d, want %d, body: %s", rr.Code, http.StatusUnprocessableEntity, rr.Body.String())
	}
}

func TestProvidersAndScoresEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/providers", map[string]interface{}{
		"name":             "anthropic",
		"rpm_limit":        4000,
		"input_tpm_limit":  400000,
		"output_tpm_limit": 80000,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set provider status = %d, body: %s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/providers", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list providers status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/queues/score.q/provider", map[string]interface{}{
		"provider": "anthropic",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set queue provider status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
		"queue":   "score.q",
		"payload": map[string]string{"k": "v"},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var enq store.EnqueueResult
	decodeResponse(t, rr, &enq)

	rr = doRequest(srv, "POST", "/api/v1/scores", map[string]interface{}{
		"job_id":    enq.JobID,
		"dimension": "accuracy",
		"value":     0.91,
		"scorer":    "auto:test",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("add score status = %d, body: %s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/jobs/"+enq.JobID+"/scores", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("job scores status = %d, body: %s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/scores/summary?queue=score.q&period=24h", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("score summary status = %d, body: %s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/scores/compare?queue=score.q&period=24h&group_by=queue", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("score compare status = %d, body: %s", rr.Code, rr.Body.String())
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

func TestJobIterationsEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "iter.q",
		"payload": map[string]string{"k": "v"},
		"agent": map[string]any{
			"max_iterations": 5,
		},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var enqResult store.EnqueueResult
	decodeResponse(t, rr, &enqResult)

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{"iter.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	var f1 store.FetchResult
	decodeResponse(t, rr, &f1)
	rr = doRequest(srv, "POST", "/api/v1/ack/"+f1.JobID, map[string]any{
		"agent_status": "continue",
		"checkpoint":   map[string]any{"step": 1},
		"trace": map[string]any{
			"model": "claude-sonnet",
			"tool_calls": []map[string]any{
				{"name": "search", "args": map[string]any{"q": "corvo"}},
			},
		},
		"usage": map[string]any{
			"cost_usd": 0.12,
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack #1 status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{"iter.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	var f2 store.FetchResult
	decodeResponse(t, rr, &f2)
	rr = doRequest(srv, "POST", "/api/v1/ack/"+f2.JobID, map[string]any{
		"agent_status": "done",
		"result":       map[string]any{"ok": true},
		"usage": map[string]any{
			"cost_usd": 0.08,
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack #2 status = %d, body: %s", rr.Code, rr.Body.String())
	}

	var out struct {
		Iterations []store.JobIteration `json:"iterations"`
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		rr = doRequest(srv, "GET", "/api/v1/jobs/"+enqResult.JobID+"/iterations", nil)
		if rr.Code != http.StatusOK {
			t.Fatalf("iterations status = %d, body: %s", rr.Code, rr.Body.String())
		}
		decodeResponse(t, rr, &out)
		if len(out.Iterations) >= 2 || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(out.Iterations) != 2 {
		t.Fatalf("iterations = %d, want 2", len(out.Iterations))
	}
	if out.Iterations[0].Status != "continue" {
		t.Fatalf("iteration 1 status = %s, want continue", out.Iterations[0].Status)
	}
	if string(out.Iterations[0].Trace) == "" {
		t.Fatalf("iteration 1 trace should be present")
	}
	if out.Iterations[1].Status != "done" {
		t.Fatalf("iteration 2 status = %s, want done", out.Iterations[1].Status)
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

func TestBulkEndpointAsyncLifecycle(t *testing.T) {
	srv, _ := testServer(t)

	var ids []string
	for range 3 {
		rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]interface{}{
			"queue": "bulk.async.q", "payload": map[string]string{},
		})
		var r store.EnqueueResult
		decodeResponse(t, rr, &r)
		ids = append(ids, r.JobID)
	}

	rr := doRequest(srv, "POST", "/api/v1/jobs/bulk", map[string]any{
		"job_ids": ids,
		"action":  "cancel",
		"async":   true,
	})
	if rr.Code != http.StatusAccepted {
		t.Fatalf("bulk async status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var start map[string]any
	decodeResponse(t, rr, &start)
	taskID, _ := start["bulk_operation_id"].(string)
	if taskID == "" {
		t.Fatalf("missing bulk_operation_id: %v", start)
	}

	deadline := time.Now().Add(2 * time.Second)
	var status bulkTask
	for {
		rr = doRequest(srv, "GET", "/api/v1/bulk/"+taskID, nil)
		if rr.Code != http.StatusOK {
			t.Fatalf("bulk status = %d, body: %s", rr.Code, rr.Body.String())
		}
		decodeResponse(t, rr, &status)
		if status.Status == bulkTaskCompleted || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if status.Status != bulkTaskCompleted {
		t.Fatalf("bulk status = %s, want completed", status.Status)
	}
	if status.Affected != 3 {
		t.Fatalf("bulk affected = %d, want 3", status.Affected)
	}

	rr = doRequest(srv, "GET", "/api/v1/bulk/"+taskID+"/progress", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("bulk progress status = %d, body: %s", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "bulk.async.completed") {
		t.Fatalf("expected completed event in progress body, got: %s", rr.Body.String())
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

func TestWebhookEndpoints(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/webhooks", map[string]any{
		"id":          "wh_test",
		"url":         "http://example.invalid/hook",
		"events":      []string{"completed", "failed"},
		"enabled":     true,
		"retry_limit": 2,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set webhook status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/webhooks", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list webhooks status = %d body=%s", rr.Code, rr.Body.String())
	}
	var hooks []map[string]any
	decodeResponse(t, rr, &hooks)
	if len(hooks) == 0 {
		t.Fatalf("expected webhook rows")
	}

	rr = doRequest(srv, "DELETE", "/api/v1/webhooks/wh_test", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("delete webhook status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestAPIKeyAuthAndNamespaceIsolation(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name":      "acme-admin",
		"key":       "k_acme_admin",
		"namespace": "acme",
		"role":      "admin",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set api key status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/queues", nil)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized without key, got %d body=%s", rr.Code, rr.Body.String())
	}

	headers := map[string]string{"X-API-Key": "k_acme_admin"}
	rr = doRequestWithHeaders(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "emails.send",
		"payload": map[string]any{"x": 1},
	}, headers)
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequestWithHeaders(srv, "GET", "/api/v1/queues", nil, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("queues status = %d body=%s", rr.Code, rr.Body.String())
	}
	var queues []map[string]any
	decodeResponse(t, rr, &queues)
	if len(queues) == 0 {
		t.Fatalf("expected queues")
	}
	if name, _ := queues[0]["name"].(string); name != "emails.send" {
		t.Fatalf("expected visible queue name without namespace prefix, got %q", name)
	}
}

func TestTenantBackupRestoreAndBilling(t *testing.T) {
	srv, _ := testServer(t)
	_ = doRequest(srv, "POST", "/api/v1/auth/keys", map[string]any{
		"name":      "acme-admin",
		"key":       "k_acme_admin",
		"namespace": "acme",
		"role":      "admin",
	})
	headers := map[string]string{"X-API-Key": "k_acme_admin"}
	rr := doRequestWithHeaders(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "billing.q",
		"payload": map[string]any{"x": 1},
	}, headers)
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d body=%s", rr.Code, rr.Body.String())
	}
	var enq store.EnqueueResult
	decodeResponse(t, rr, &enq)

	rr = doRequestWithHeaders(srv, "POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{"billing.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	}, headers)
	var f store.FetchResult
	decodeResponse(t, rr, &f)
	rr = doRequestWithHeaders(srv, "POST", "/api/v1/ack/"+f.JobID, map[string]any{
		"usage": map[string]any{
			"input_tokens":  10,
			"output_tokens": 5,
			"cost_usd":      0.01,
		},
	}, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("ack status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequestWithHeaders(srv, "GET", "/api/v1/admin/backup?namespace=acme", nil, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("backup status = %d body=%s", rr.Code, rr.Body.String())
	}
	var backup map[string]any
	decodeResponse(t, rr, &backup)
	if backup["namespace"] != "acme" {
		t.Fatalf("backup namespace = %v", backup["namespace"])
	}

	rr = doRequestWithHeaders(srv, "POST", "/api/v1/admin/restore", map[string]any{
		"namespace": "acme",
		"jobs": []map[string]any{
			{"queue": "restore.q", "payload": map[string]any{"a": 1}, "priority": 2},
		},
	}, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("restore status = %d body=%s", rr.Code, rr.Body.String())
	}

	rr = doRequestWithHeaders(srv, "GET", "/api/v1/billing/summary?period=24h", nil, headers)
	if rr.Code != http.StatusOK {
		t.Fatalf("billing summary status = %d body=%s", rr.Code, rr.Body.String())
	}
	var bill map[string]any
	decodeResponse(t, rr, &bill)
	if _, ok := bill["summary"]; !ok {
		t.Fatalf("billing summary missing summary field: %v", bill)
	}

	_ = enq
}

func TestFullTextSearchEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "fts.q",
		"payload": map[string]any{"message": "hello vector world"},
		"tags":    map[string]any{"topic": "hello"},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d body=%s", rr.Code, rr.Body.String())
	}
	rr = doRequest(srv, "GET", "/api/v1/search/fulltext?q=hello", nil)
	deadline := time.Now().Add(2 * time.Second)
	for {
		if rr.Code != http.StatusOK {
			t.Fatalf("fulltext status = %d body=%s", rr.Code, rr.Body.String())
		}
		var body map[string]any
		decodeResponse(t, rr, &body)
		results, _ := body["results"].([]any)
		if len(results) > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("expected fulltext results")
		}
		time.Sleep(25 * time.Millisecond)
		rr = doRequest(srv, "GET", "/api/v1/search/fulltext?q=hello", nil)
	}
}

func TestApprovalPolicyEndpointsAndAutoHold(t *testing.T) {
	srv, _ := testServer(t)

	rr := doRequest(srv, "POST", "/api/v1/approval-policies", map[string]any{
		"name":            "hold-risky-action",
		"mode":            "all",
		"queue":           "apol.q",
		"trace_action_in": []string{"send_email"},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("set policy status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/approval-policies", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list policy status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "apol.q",
		"payload": map[string]string{"task": "x"},
		"agent": map[string]any{
			"max_iterations": 4,
		},
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("enqueue status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var enq store.EnqueueResult
	decodeResponse(t, rr, &enq)

	rr = doRequest(srv, "POST", "/api/v1/fetch", map[string]any{
		"queues":    []string{"apol.q"},
		"worker_id": "w1",
		"hostname":  "h1",
		"timeout":   1,
	})
	var f store.FetchResult
	decodeResponse(t, rr, &f)
	rr = doRequest(srv, "POST", "/api/v1/ack/"+f.JobID, map[string]any{
		"agent_status": "continue",
		"trace": map[string]any{
			"action": "send_email",
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("ack status = %d, body: %s", rr.Code, rr.Body.String())
	}

	rr = doRequest(srv, "GET", "/api/v1/jobs/"+enq.JobID, nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("get job status = %d, body: %s", rr.Code, rr.Body.String())
	}
	var job store.Job
	decodeResponse(t, rr, &job)
	if job.State != store.StateHeld {
		t.Fatalf("job state = %s, want held", job.State)
	}
	if job.HoldReason == nil || *job.HoldReason == "" {
		t.Fatalf("expected hold_reason to be set")
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

func TestClusterJoinEndpoint(t *testing.T) {
	_, s := testServer(t)
	cl := &mockClusterWithVoter{mockCluster: mockCluster{isLeader: true}}
	srv := New(s, cl, ":0", nil)

	rr := doRequest(srv, "POST", "/api/v1/cluster/join", map[string]any{
		"node_id": "node-2",
		"addr":    "127.0.0.1:9400",
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("join status = %d, body: %s", rr.Code, rr.Body.String())
	}
	if len(cl.added) != 1 {
		t.Fatalf("expected add voter call")
	}
}

func TestClusterJoinEndpointShard(t *testing.T) {
	_, s := testServer(t)
	cl := &mockShardCluster{
		mockCluster: mockCluster{isLeader: true},
		shardCount:  2,
		localShards: map[int]bool{0: true, 1: true},
	}
	srv := New(s, cl, ":0", nil)

	rr := doRequest(srv, "POST", "/api/v1/cluster/join", map[string]any{
		"node_id":     "node-2-s01",
		"addr":        "127.0.0.1:9401",
		"shard":       1,
		"shard_count": 2,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("join status = %d, body: %s", rr.Code, rr.Body.String())
	}
	if len(cl.added) != 1 || !strings.HasSuffix(cl.added[0], "#1") {
		t.Fatalf("expected shard add voter call, got %v", cl.added)
	}
}

func TestClusterJoinEndpointShardCountMismatch(t *testing.T) {
	_, s := testServer(t)
	cl := &mockShardCluster{
		mockCluster: mockCluster{isLeader: true},
		shardCount:  2,
		localShards: map[int]bool{0: true, 1: true},
	}
	srv := New(s, cl, ":0", nil)

	rr := doRequest(srv, "POST", "/api/v1/cluster/join", map[string]any{
		"node_id":     "node-2-s01",
		"addr":        "127.0.0.1:9401",
		"shard":       1,
		"shard_count": 4,
	})
	if rr.Code != http.StatusConflict {
		t.Fatalf("join status = %d, body: %s", rr.Code, rr.Body.String())
	}
}

func TestPrometheusMetricsEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	doRequest(srv, "POST", "/api/v1/enqueue", map[string]any{
		"queue":   "metrics.q",
		"payload": map[string]any{"x": 1},
	})

	rr := doRequest(srv, "GET", "/api/v1/metrics", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("metrics status = %d, body: %s", rr.Code, rr.Body.String())
	}
	if ct := rr.Header().Get("Content-Type"); !strings.Contains(ct, "text/plain") {
		t.Fatalf("content-type = %q, want text/plain", ct)
	}
	body := rr.Body.String()
	for _, needle := range []string{
		"corvo_throughput_enqueued_total",
		"corvo_queues_total",
		"corvo_queue_jobs",
		"corvo_jobs",
	} {
		if !strings.Contains(body, needle) {
			t.Fatalf("metrics body missing %q", needle)
		}
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

func TestWriteRejectsMixedShardLeaders(t *testing.T) {
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()
	s := store.NewStore(da, da.SQLiteDB())
	defer s.Close()

	cl := &mockShardCluster{
		mockCluster: mockCluster{isLeader: false},
		shardCount:  2,
		localShards: map[int]bool{
			0: false,
			1: false,
		},
		shardLeaders: map[int]string{
			0: "http://leader-a:8080",
			1: "http://leader-b:8080",
		},
	}
	srv := New(s, cl, ":0", nil)
	rr := doRequest(srv, "POST", "/api/v1/enqueue/batch", map[string]any{
		"jobs": []map[string]any{
			{"queue": "q0", "payload": map[string]any{}},
			{"queue": "q1", "payload": map[string]any{}},
		},
	})
	if rr.Code != http.StatusConflict {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestWriteRejectsMixedLocalRemoteShardLeaders(t *testing.T) {
	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("NewDirectApplier: %v", err)
	}
	defer da.Close()
	s := store.NewStore(da, da.SQLiteDB())
	defer s.Close()

	cl := &mockShardCluster{
		mockCluster: mockCluster{isLeader: false},
		shardCount:  2,
		localShards: map[int]bool{
			0: true,
			1: false,
		},
		shardLeaders: map[int]string{
			0: "http://127.0.0.1:28080",
			1: "http://127.0.0.1:28081",
		},
	}
	srv := New(s, cl, ":0", nil)
	rr := doRequest(srv, "POST", "/api/v1/enqueue/batch", map[string]any{
		"jobs": []map[string]any{
			{"queue": "q0", "payload": map[string]any{}},
			{"queue": "q1", "payload": map[string]any{}},
		},
	})
	if rr.Code != http.StatusConflict {
		t.Fatalf("status = %d body=%s", rr.Code, rr.Body.String())
	}
}

func TestConnectWorkerLifecycle(t *testing.T) {
	srv, s := testServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	client := corvov1connect.NewWorkerServiceClient(ts.Client(), ts.URL)

	enqResp, err := client.Enqueue(context.Background(), connect.NewRequest(&corvov1.EnqueueRequest{
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

	fetchResp, err := client.Fetch(context.Background(), connect.NewRequest(&corvov1.FetchRequest{
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

	if _, err := client.Ack(context.Background(), connect.NewRequest(&corvov1.AckRequest{
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
	client := corvov1connect.NewWorkerServiceClient(httpClient, ts.URL)
	if _, err := client.Enqueue(context.Background(), connect.NewRequest(&corvov1.EnqueueRequest{
		Queue:       "connect.stream.q",
		PayloadJson: `{}`,
	})); err != nil {
		t.Fatalf("connect enqueue 1: %v", err)
	}
	if _, err := client.Enqueue(context.Background(), connect.NewRequest(&corvov1.EnqueueRequest{
		Queue:       "connect.stream.q",
		PayloadJson: `{}`,
	})); err != nil {
		t.Fatalf("connect enqueue 2: %v", err)
	}

	stream := client.StreamLifecycle(context.Background())
	defer stream.CloseRequest()

	if err := stream.Send(&corvov1.LifecycleStreamRequest{
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

	acks := make([]*corvov1.AckBatchItem, 0, 2)
	for _, job := range fetchResp.GetJobs() {
		acks = append(acks, &corvov1.AckBatchItem{JobId: job.GetJobId(), ResultJson: `{"ok":true}`})
	}
	if err := stream.Send(&corvov1.LifecycleStreamRequest{
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
