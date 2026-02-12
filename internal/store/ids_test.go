package store

import (
	"strings"
	"testing"
)

func TestNewJobID(t *testing.T) {
	id := NewJobID()
	if !strings.HasPrefix(id, "job_") {
		t.Errorf("NewJobID() = %q, want prefix %q", id, "job_")
	}
	// ULID is 26 chars + 4 prefix = 30
	if len(id) != 30 {
		t.Errorf("NewJobID() length = %d, want 30", len(id))
	}
}

func TestNewBatchID(t *testing.T) {
	id := NewBatchID()
	if !strings.HasPrefix(id, "batch_") {
		t.Errorf("NewBatchID() = %q, want prefix %q", id, "batch_")
	}
}

func TestNewScheduleID(t *testing.T) {
	id := NewScheduleID()
	if !strings.HasPrefix(id, "sched_") {
		t.Errorf("NewScheduleID() = %q, want prefix %q", id, "sched_")
	}
}

func TestIDsAreUnique(t *testing.T) {
	seen := make(map[string]bool)
	for range 1000 {
		id := NewJobID()
		if seen[id] {
			t.Fatalf("duplicate ID generated: %s", id)
		}
		seen[id] = true
	}
}

func TestIDsAreSortable(t *testing.T) {
	ids := make([]string, 100)
	for i := range ids {
		ids[i] = NewJobID()
	}
	for i := 1; i < len(ids); i++ {
		if ids[i] < ids[i-1] {
			t.Errorf("IDs not sortable: %q < %q at index %d", ids[i], ids[i-1], i)
		}
	}
}

func TestPriorityConversions(t *testing.T) {
	tests := []struct {
		str string
		val int
	}{
		{"critical", PriorityCritical},
		{"high", PriorityHigh},
		{"normal", PriorityNormal},
		{"unknown", PriorityNormal},
		{"", PriorityNormal},
	}

	for _, tt := range tests {
		got := PriorityFromString(tt.str)
		if got != tt.val {
			t.Errorf("PriorityFromString(%q) = %d, want %d", tt.str, got, tt.val)
		}
	}

	if PriorityToString(PriorityCritical) != "critical" {
		t.Error("PriorityToString(0) != critical")
	}
	if PriorityToString(PriorityHigh) != "high" {
		t.Error("PriorityToString(1) != high")
	}
	if PriorityToString(PriorityNormal) != "normal" {
		t.Error("PriorityToString(2) != normal")
	}
	if PriorityToString(99) != "normal" {
		t.Error("PriorityToString(99) != normal")
	}
}
