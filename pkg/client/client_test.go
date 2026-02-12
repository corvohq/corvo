package client

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/user/jobbie/internal/server"
	"github.com/user/jobbie/internal/store"
)

func testClient(t *testing.T) *Client {
	t.Helper()
	db, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	s := store.NewStore(db)
	srv := server.New(s, ":0")
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	return New(ts.URL)
}

func TestClientEnqueue(t *testing.T) {
	c := testClient(t)

	result, err := c.Enqueue("test.queue", map[string]string{"hello": "world"})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	if result.JobID == "" {
		t.Error("job ID is empty")
	}
	if result.Status != "pending" {
		t.Errorf("status = %q, want pending", result.Status)
	}
}

func TestClientEnqueueWithOptions(t *testing.T) {
	c := testClient(t)

	result, err := c.Enqueue("test.queue", map[string]string{},
		WithPriority("critical"),
		WithMaxRetries(5),
		WithUniqueKey("unique-1", 3600),
		WithTags(map[string]string{"env": "test"}),
	)
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	if result.JobID == "" {
		t.Error("job ID is empty")
	}
}

func TestClientEnqueueBatch(t *testing.T) {
	c := testClient(t)

	result, err := c.EnqueueBatch(BatchRequest{
		Jobs: []BatchJob{
			{Queue: "batch.q", Payload: map[string]int{"i": 1}},
			{Queue: "batch.q", Payload: map[string]int{"i": 2}},
		},
		Batch: &BatchConfig{
			CallbackQueue: "batch.done",
		},
	})
	if err != nil {
		t.Fatalf("EnqueueBatch: %v", err)
	}
	if len(result.JobIDs) != 2 {
		t.Errorf("job IDs count = %d, want 2", len(result.JobIDs))
	}
	if result.BatchID == "" {
		t.Error("batch ID is empty")
	}
}

func TestClientGetJob(t *testing.T) {
	c := testClient(t)

	enqResult, _ := c.Enqueue("test.queue", map[string]string{"k": "v"})

	job, err := c.GetJob(enqResult.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.ID != enqResult.JobID {
		t.Errorf("job ID = %q, want %q", job.ID, enqResult.JobID)
	}
	if job.State != "pending" {
		t.Errorf("state = %q, want pending", job.State)
	}
}

func TestClientSearch(t *testing.T) {
	c := testClient(t)

	c.Enqueue("search.q", map[string]string{})
	c.Enqueue("search.q", map[string]string{})

	result, err := c.Search(SearchFilter{Queue: "search.q"})
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if result.Total != 2 {
		t.Errorf("total = %d, want 2", result.Total)
	}
}

func TestClientListQueues(t *testing.T) {
	c := testClient(t)

	c.Enqueue("q1", map[string]string{})

	data, err := c.ListQueues()
	if err != nil {
		t.Fatalf("ListQueues: %v", err)
	}

	var queues []map[string]interface{}
	json.Unmarshal(data, &queues)
	if len(queues) != 1 {
		t.Errorf("queues count = %d, want 1", len(queues))
	}
}

func TestClientGetJobNotFound(t *testing.T) {
	c := testClient(t)
	_, err := c.GetJob("nonexistent")
	if err == nil {
		t.Error("GetJob should error for nonexistent job")
	}
}
