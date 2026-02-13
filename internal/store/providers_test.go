package store_test

import (
	"encoding/json"
	"testing"

	"github.com/user/jobbie/internal/store"
)

func TestProviderRPMFetchLimit(t *testing.T) {
	s := testStore(t)

	if _, err := s.SetProvider(store.SetProviderRequest{
		Name:     "anthropic",
		RPMLimit: intPtr(1),
	}); err != nil {
		t.Fatalf("SetProvider: %v", err)
	}
	if err := s.SetQueueProvider("provider.rpm", "anthropic"); err != nil {
		t.Fatalf("SetQueueProvider: %v", err)
	}

	for i := 0; i < 2; i++ {
		if _, err := s.Enqueue(store.EnqueueRequest{Queue: "provider.rpm", Payload: json.RawMessage(`{}`)}); err != nil {
			t.Fatalf("Enqueue #%d: %v", i+1, err)
		}
	}

	j1, err := s.Fetch(store.FetchRequest{Queues: []string{"provider.rpm"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #1: %v", err)
	}
	if j1 == nil {
		t.Fatal("Fetch #1 returned nil")
	}

	j2, err := s.Fetch(store.FetchRequest{Queues: []string{"provider.rpm"}, WorkerID: "w2", Hostname: "h2"})
	if err != nil {
		t.Fatalf("Fetch #2: %v", err)
	}
	if j2 != nil {
		t.Fatalf("Fetch #2 = %s, want nil due to provider rpm limit", j2.JobID)
	}
}

func TestProviderTokenFetchLimit(t *testing.T) {
	s := testStore(t)

	if _, err := s.SetProvider(store.SetProviderRequest{
		Name:          "anthropic",
		InputTPMLimit: intPtr(100),
	}); err != nil {
		t.Fatalf("SetProvider: %v", err)
	}
	if err := s.SetQueueProvider("provider.tpm", "anthropic"); err != nil {
		t.Fatalf("SetQueueProvider: %v", err)
	}

	r1, err := s.Enqueue(store.EnqueueRequest{Queue: "provider.tpm", Payload: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatalf("Enqueue #1: %v", err)
	}
	f1, err := s.Fetch(store.FetchRequest{Queues: []string{"provider.tpm"}, WorkerID: "w1", Hostname: "h1"})
	if err != nil {
		t.Fatalf("Fetch #1: %v", err)
	}
	if f1 == nil {
		t.Fatal("Fetch #1 returned nil")
	}
	if err := s.AckJob(store.AckRequest{
		JobID:  r1.JobID,
		Result: json.RawMessage(`{"ok":true}`),
		Usage: &store.UsageReport{
			InputTokens: 120,
			Provider:    "anthropic",
			Model:       "claude",
		},
	}); err != nil {
		t.Fatalf("Ack #1: %v", err)
	}

	if _, err := s.Enqueue(store.EnqueueRequest{Queue: "provider.tpm", Payload: json.RawMessage(`{}`)}); err != nil {
		t.Fatalf("Enqueue #2: %v", err)
	}
	f2, err := s.Fetch(store.FetchRequest{Queues: []string{"provider.tpm"}, WorkerID: "w2", Hostname: "h2"})
	if err != nil {
		t.Fatalf("Fetch #2: %v", err)
	}
	if f2 != nil {
		t.Fatalf("Fetch #2 = %s, want nil due to input_tpm limit", f2.JobID)
	}
}

func intPtr(v int) *int { return &v }
