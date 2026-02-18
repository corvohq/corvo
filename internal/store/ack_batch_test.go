package store_test

import (
	"testing"

	"github.com/corvohq/corvo/internal/store"
)

func TestAckBatchMissingJobDoesNotError(t *testing.T) {
	s := testStore(t)
	acked, err := s.AckBatch([]store.AckOp{{JobID: "missing-job"}})
	if err != nil {
		t.Fatalf("AckBatch error = %v, want nil", err)
	}
	if acked != 0 {
		t.Fatalf("acked = %d, want 0", acked)
	}
}
