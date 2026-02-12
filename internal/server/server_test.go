package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/user/jobbie/internal/store"
)

func testServer(t *testing.T) (*Server, *store.Store) {
	t.Helper()
	db, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	s := store.NewStore(db)
	srv := New(s, ":0")
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

func TestClusterStatusEndpoint(t *testing.T) {
	srv, _ := testServer(t)
	rr := doRequest(srv, "GET", "/api/v1/cluster/status", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("cluster status = %d", rr.Code)
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
