package integration

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/user/jobbie/internal/raft"
	"github.com/user/jobbie/internal/scheduler"
	"github.com/user/jobbie/internal/server"
	"github.com/user/jobbie/internal/store"
	"github.com/user/jobbie/pkg/client"
)

// testEnv holds a fully wired test stack.
type testEnv struct {
	client *client.Client
	sched  *scheduler.Scheduler
	url    string
	httpC  *http.Client
}

func setup(t *testing.T) *testEnv {
	t.Helper()

	da, err := raft.NewDirectApplier(t.TempDir())
	if err != nil {
		t.Fatalf("raft.NewDirectApplier: %v", err)
	}
	t.Cleanup(func() { da.Close() })

	s := store.NewStore(da, da.SQLiteDB())
	t.Cleanup(func() { s.Close() })
	sched := scheduler.New(s, nil, scheduler.DefaultConfig())
	srv := server.New(s, nil, ":0", nil)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	c := client.New(ts.URL)

	return &testEnv{
		client: c,
		sched:  sched,
		url:    ts.URL,
		httpC:  ts.Client(),
	}
}

// --- HTTP helpers for APIs not exposed by the client library ---

type fetchRequest struct {
	Queues   []string `json:"queues"`
	WorkerID string   `json:"worker_id"`
	Hostname string   `json:"hostname"`
	Timeout  int      `json:"timeout"`
}

type fetchResult struct {
	JobID      string          `json:"job_id"`
	Queue      string          `json:"queue"`
	Payload    json.RawMessage `json:"payload"`
	Attempt    int             `json:"attempt"`
	MaxRetries int             `json:"max_retries"`
	Checkpoint json.RawMessage `json:"checkpoint,omitempty"`
}

func (e *testEnv) fetch(t *testing.T, queues []string) *fetchResult {
	t.Helper()
	body, _ := json.Marshal(fetchRequest{
		Queues:   queues,
		WorkerID: "test-worker",
		Hostname: "test-host",
		Timeout:  1,
	})
	resp, err := e.httpC.Post(e.url+"/api/v1/fetch", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return nil
	}
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("fetch: status %d: %s", resp.StatusCode, data)
	}
	var result fetchResult
	json.NewDecoder(resp.Body).Decode(&result)
	return &result
}

func (e *testEnv) ack(t *testing.T, jobID string) {
	t.Helper()
	body, _ := json.Marshal(map[string]interface{}{})
	resp, err := e.httpC.Post(e.url+"/api/v1/ack/"+jobID, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("ack: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("ack: status %d: %s", resp.StatusCode, data)
	}
}

type failResponse struct {
	Status            string `json:"status"`
	AttemptsRemaining int    `json:"attempts_remaining"`
}

func (e *testEnv) fail(t *testing.T, jobID string, errMsg string) *failResponse {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"error": errMsg})
	resp, err := e.httpC.Post(e.url+"/api/v1/fail/"+jobID, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("fail: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("fail: status %d: %s", resp.StatusCode, data)
	}
	var result failResponse
	json.NewDecoder(resp.Body).Decode(&result)
	return &result
}

type heartbeatResponse struct {
	Jobs map[string]struct {
		Status string `json:"status"`
	} `json:"jobs"`
}

func (e *testEnv) heartbeat(t *testing.T, jobs map[string]interface{}) *heartbeatResponse {
	t.Helper()
	body, _ := json.Marshal(map[string]interface{}{"jobs": jobs})
	resp, err := e.httpC.Post(e.url+"/api/v1/heartbeat", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("heartbeat: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("heartbeat: status %d: %s", resp.StatusCode, data)
	}
	var result heartbeatResponse
	json.NewDecoder(resp.Body).Decode(&result)
	return &result
}

type bulkResponse struct {
	Affected int `json:"affected"`
}

func (e *testEnv) bulk(t *testing.T, action string, jobIDs []string) *bulkResponse {
	t.Helper()
	body, _ := json.Marshal(map[string]interface{}{
		"action":  action,
		"job_ids": jobIDs,
	})
	resp, err := e.httpC.Post(e.url+"/api/v1/jobs/bulk", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("bulk: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		t.Fatalf("bulk: status %d: %s", resp.StatusCode, data)
	}
	var result bulkResponse
	json.NewDecoder(resp.Body).Decode(&result)
	return &result
}

// --- Integration Tests ---

func TestJobLifecycle(t *testing.T) {
	e := setup(t)

	// Enqueue
	enqResult, err := e.client.Enqueue("lifecycle.q", map[string]string{"action": "test"})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	if enqResult.JobID == "" {
		t.Fatal("job ID is empty")
	}

	// Fetch
	fetched := e.fetch(t, []string{"lifecycle.q"})
	if fetched == nil {
		t.Fatal("expected a job, got nil")
	}
	if fetched.JobID != enqResult.JobID {
		t.Errorf("fetched job ID = %q, want %q", fetched.JobID, enqResult.JobID)
	}

	// Ack
	e.ack(t, fetched.JobID)

	// Verify completed
	job, err := e.client.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.State != "completed" {
		t.Errorf("state = %q, want completed", job.State)
	}
}

func TestFailAndRetry(t *testing.T) {
	e := setup(t)

	// Enqueue with max_retries=2 and no backoff (so scheduler promotes immediately)
	enqResult, err := e.client.Enqueue("retry.q", map[string]string{},
		client.WithMaxRetries(2),
		client.WithRetryBackoff("none", "", ""),
	)
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Fetch
	fetched := e.fetch(t, []string{"retry.q"})
	if fetched == nil {
		t.Fatal("expected a job")
	}

	// Fail — should have 1 attempt remaining
	failResult := e.fail(t, fetched.JobID, "something broke")
	if failResult.Status != "retrying" {
		t.Errorf("fail status = %q, want retrying", failResult.Status)
	}
	if failResult.AttemptsRemaining != 1 {
		t.Errorf("attempts remaining = %d, want 1", failResult.AttemptsRemaining)
	}

	// RunOnce promotes retrying → pending (backoff=none means scheduled_at=now)
	e.sched.RunOnce()

	// Fetch again — should get the same job at attempt 2
	fetched2 := e.fetch(t, []string{"retry.q"})
	if fetched2 == nil {
		t.Fatal("expected job after retry promotion")
	}
	if fetched2.JobID != enqResult.JobID {
		t.Errorf("fetched job ID = %q, want %q", fetched2.JobID, enqResult.JobID)
	}
	if fetched2.Attempt != 2 {
		t.Errorf("attempt = %d, want 2", fetched2.Attempt)
	}
}

func TestDeadLetter(t *testing.T) {
	e := setup(t)

	// max_retries=2: attempt 1 fail → retrying (1 remaining), attempt 2 fail → dead (0 remaining)
	enqResult, err := e.client.Enqueue("dead.q", map[string]string{},
		client.WithMaxRetries(2),
		client.WithRetryBackoff("none", "", ""),
	)
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Attempt 1: fetch + fail → retrying
	fetched := e.fetch(t, []string{"dead.q"})
	if fetched == nil {
		t.Fatal("expected a job")
	}
	failResult := e.fail(t, fetched.JobID, "error 1")
	if failResult.Status != "retrying" {
		t.Fatalf("expected retrying, got %q", failResult.Status)
	}

	// Promote and attempt 2: fetch + fail → dead
	e.sched.RunOnce()
	fetched2 := e.fetch(t, []string{"dead.q"})
	if fetched2 == nil {
		t.Fatal("expected job after promotion")
	}
	failResult2 := e.fail(t, fetched2.JobID, "error 2")
	if failResult2.Status != "dead" {
		t.Errorf("expected dead, got %q", failResult2.Status)
	}

	// Verify via GetJob
	job, err := e.client.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.State != "dead" {
		t.Errorf("state = %q, want dead", job.State)
	}
}

func TestPriorityOrdering(t *testing.T) {
	e := setup(t)

	// Enqueue normal first, then critical
	_, err := e.client.Enqueue("prio.q", map[string]string{"level": "normal"})
	if err != nil {
		t.Fatalf("Enqueue normal: %v", err)
	}
	critResult, err := e.client.Enqueue("prio.q", map[string]string{"level": "critical"},
		client.WithPriority("critical"),
	)
	if err != nil {
		t.Fatalf("Enqueue critical: %v", err)
	}

	// Fetch should return critical first (priority 0 < 2)
	fetched := e.fetch(t, []string{"prio.q"})
	if fetched == nil {
		t.Fatal("expected a job")
	}
	if fetched.JobID != critResult.JobID {
		t.Errorf("expected critical job %q first, got %q", critResult.JobID, fetched.JobID)
	}
}

func TestUniqueJobs(t *testing.T) {
	e := setup(t)

	// First enqueue
	result1, err := e.client.Enqueue("unique.q", map[string]string{},
		client.WithUniqueKey("dedup-key-1", 3600),
	)
	if err != nil {
		t.Fatalf("Enqueue 1: %v", err)
	}
	if result1.UniqueExisting {
		t.Error("first enqueue should not be unique_existing")
	}

	// Second enqueue with same key — should return existing
	result2, err := e.client.Enqueue("unique.q", map[string]string{},
		client.WithUniqueKey("dedup-key-1", 3600),
	)
	if err != nil {
		t.Fatalf("Enqueue 2: %v", err)
	}
	if !result2.UniqueExisting {
		t.Error("second enqueue should be unique_existing")
	}
	if result2.JobID != result1.JobID {
		t.Errorf("duplicate job ID = %q, want %q", result2.JobID, result1.JobID)
	}
}

func TestQueuePauseResume(t *testing.T) {
	e := setup(t)

	_, err := e.client.Enqueue("pausable.q", map[string]string{})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Pause
	if err := e.client.PauseQueue("pausable.q"); err != nil {
		t.Fatalf("PauseQueue: %v", err)
	}

	// Fetch should return nothing (queue paused)
	fetched := e.fetch(t, []string{"pausable.q"})
	if fetched != nil {
		t.Errorf("expected nil from paused queue, got job %q", fetched.JobID)
	}

	// Resume
	if err := e.client.ResumeQueue("pausable.q"); err != nil {
		t.Fatalf("ResumeQueue: %v", err)
	}

	// Fetch should now work
	fetched = e.fetch(t, []string{"pausable.q"})
	if fetched == nil {
		t.Error("expected a job after resume, got nil")
	}
}

func TestSearch(t *testing.T) {
	e := setup(t)

	// Enqueue on two different queues
	e.client.Enqueue("search.alpha", map[string]string{"x": "1"})
	e.client.Enqueue("search.alpha", map[string]string{"x": "2"})
	e.client.Enqueue("search.beta", map[string]string{"x": "3"})

	// Search for alpha queue only
	result, err := e.client.Search(client.SearchFilter{Queue: "search.alpha"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if result.Total != 2 {
		t.Errorf("total = %d, want 2", result.Total)
	}

	// Search for beta queue
	result, err = e.client.Search(client.SearchFilter{Queue: "search.beta"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if result.Total != 1 {
		t.Errorf("total = %d, want 1", result.Total)
	}
}

func TestBulkOperations(t *testing.T) {
	e := setup(t)

	r1, _ := e.client.Enqueue("bulk.q", map[string]string{"i": "1"})
	r2, _ := e.client.Enqueue("bulk.q", map[string]string{"i": "2"})
	r3, _ := e.client.Enqueue("bulk.q", map[string]string{"i": "3"})

	// Bulk cancel
	bulkResult := e.bulk(t, "cancel", []string{r1.JobID, r2.JobID, r3.JobID})
	if bulkResult.Affected != 3 {
		t.Errorf("affected = %d, want 3", bulkResult.Affected)
	}

	// Verify all cancelled
	for _, id := range []string{r1.JobID, r2.JobID, r3.JobID} {
		job, err := e.client.GetJob(id)
		if err != nil {
			t.Fatalf("GetJob %s: %v", id, err)
		}
		if job.State != "cancelled" {
			t.Errorf("job %s state = %q, want cancelled", id, job.State)
		}
	}
}

func TestCancellation(t *testing.T) {
	e := setup(t)

	enqResult, err := e.client.Enqueue("cancel.q", map[string]string{})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Fetch to make it active
	fetched := e.fetch(t, []string{"cancel.q"})
	if fetched == nil {
		t.Fatal("expected a job")
	}

	// Cancel via API (while active)
	if err := e.client.CancelJob(enqResult.JobID); err != nil {
		t.Fatalf("CancelJob: %v", err)
	}

	// Heartbeat should return "cancel"
	hbResult := e.heartbeat(t, map[string]interface{}{
		enqResult.JobID: map[string]interface{}{},
	})
	status := hbResult.Jobs[enqResult.JobID].Status
	if status != "cancel" {
		t.Errorf("heartbeat status = %q, want cancel", status)
	}
}

func TestHeartbeatCheckpoint(t *testing.T) {
	e := setup(t)

	_, err := e.client.Enqueue("checkpoint.q", map[string]string{},
		client.WithMaxRetries(2),
		client.WithRetryBackoff("none", "", ""),
	)
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	// Fetch
	fetched := e.fetch(t, []string{"checkpoint.q"})
	if fetched == nil {
		t.Fatal("expected a job")
	}

	// Heartbeat with checkpoint
	checkpoint := map[string]interface{}{"page": 42, "cursor": "abc"}
	e.heartbeat(t, map[string]interface{}{
		fetched.JobID: map[string]interface{}{
			"checkpoint": checkpoint,
		},
	})

	// Fail the job
	e.fail(t, fetched.JobID, "crash")

	// Promote retrying → pending
	e.sched.RunOnce()

	// Re-fetch — checkpoint should be preserved
	fetched2 := e.fetch(t, []string{"checkpoint.q"})
	if fetched2 == nil {
		t.Fatal("expected job after retry")
	}
	if fetched2.Checkpoint == nil {
		t.Fatal("checkpoint is nil after re-fetch")
	}

	var cp map[string]interface{}
	if err := json.Unmarshal(fetched2.Checkpoint, &cp); err != nil {
		t.Fatalf("unmarshal checkpoint: %v", err)
	}
	if cp["cursor"] != "abc" {
		t.Errorf("checkpoint cursor = %v, want abc", cp["cursor"])
	}
	if cp["page"] != float64(42) {
		t.Errorf("checkpoint page = %v, want 42", cp["page"])
	}
}
