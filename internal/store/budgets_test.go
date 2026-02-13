package store_test

import (
	"encoding/json"
	"testing"

	"github.com/user/jobbie/internal/store"
)

func TestBudgetCRUD(t *testing.T) {
	s := testStore(t)
	daily := 10.0
	perJob := 2.5
	b, err := s.SetBudget(store.SetBudgetRequest{
		Scope:     store.BudgetScopeQueue,
		Target:    "ai.queue",
		DailyUSD:  &daily,
		PerJobUSD: &perJob,
		OnExceed:  store.BudgetOnExceedHold,
	})
	if err != nil {
		t.Fatalf("SetBudget: %v", err)
	}
	if b.Scope != store.BudgetScopeQueue || b.Target != "ai.queue" {
		t.Fatalf("budget mismatch: %+v", b)
	}
	all, err := s.ListBudgets()
	if err != nil {
		t.Fatalf("ListBudgets: %v", err)
	}
	if len(all) != 1 {
		t.Fatalf("len(all) = %d, want 1", len(all))
	}
	if err := s.DeleteBudget(store.BudgetScopeQueue, "ai.queue"); err != nil {
		t.Fatalf("DeleteBudget: %v", err)
	}
	all, err = s.ListBudgets()
	if err != nil {
		t.Fatalf("ListBudgets(2): %v", err)
	}
	if len(all) != 0 {
		t.Fatalf("len(all) = %d, want 0", len(all))
	}
}

func TestQueueBudgetRejectBlocksFetch(t *testing.T) {
	s := testStore(t)
	daily := 0.0
	if _, err := s.SetBudget(store.SetBudgetRequest{
		Scope:    store.BudgetScopeQueue,
		Target:   "budget.reject",
		DailyUSD: &daily,
		OnExceed: store.BudgetOnExceedReject,
	}); err != nil {
		t.Fatalf("SetBudget: %v", err)
	}
	if _, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "budget.reject",
		Payload: json.RawMessage(`{}`),
	}); err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	_, err := s.Fetch(store.FetchRequest{
		Queues:   []string{"budget.reject"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err == nil || !store.IsBudgetExceededError(err) {
		t.Fatalf("Fetch err = %v, want budget exceeded", err)
	}
}

func TestQueueBudgetHoldMovesPendingToHeld(t *testing.T) {
	s := testStore(t)
	daily := 0.0
	if _, err := s.SetBudget(store.SetBudgetRequest{
		Scope:    store.BudgetScopeQueue,
		Target:   "budget.hold",
		DailyUSD: &daily,
		OnExceed: store.BudgetOnExceedHold,
	}); err != nil {
		t.Fatalf("SetBudget: %v", err)
	}
	enq, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "budget.hold",
		Payload: json.RawMessage(`{}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}
	got, err := s.Fetch(store.FetchRequest{
		Queues:   []string{"budget.hold"},
		WorkerID: "w1",
		Hostname: "h1",
	})
	if err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if got != nil {
		t.Fatalf("got job %s, want nil due to hold policy", got.JobID)
	}
	job, err := s.GetJob(enq.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.State != store.StateHeld {
		t.Fatalf("state = %q, want %q", job.State, store.StateHeld)
	}
}
