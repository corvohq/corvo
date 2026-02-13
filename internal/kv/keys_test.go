package kv

import (
	"bytes"
	"testing"
)

func TestJobKeyRoundTrip(t *testing.T) {
	k := JobKey("job_ABC123")
	if !bytes.HasPrefix(k, []byte(PrefixJob)) {
		t.Fatal("missing prefix")
	}
	id := string(k[len(PrefixJob):])
	if id != "job_ABC123" {
		t.Errorf("job id: got %q, want %q", id, "job_ABC123")
	}
}

func TestPendingKeySortOrder(t *testing.T) {
	// Same queue: higher priority (lower number) sorts first.
	k1 := PendingKey("default", 0, 100, "job_a")
	k2 := PendingKey("default", 1, 100, "job_b")
	if bytes.Compare(k1, k2) >= 0 {
		t.Error("priority 0 should sort before priority 1")
	}

	// Same queue, same priority: earlier created sorts first.
	k3 := PendingKey("default", 1, 100, "job_c")
	k4 := PendingKey("default", 1, 200, "job_d")
	if bytes.Compare(k3, k4) >= 0 {
		t.Error("earlier creation should sort before later")
	}

	// Same queue, same priority, same time: lexicographic on job_id.
	k5 := PendingKey("default", 1, 100, "job_a")
	k6 := PendingKey("default", 1, 100, "job_b")
	if bytes.Compare(k5, k6) >= 0 {
		t.Error("job_a should sort before job_b")
	}
}

func TestPendingPrefixSeek(t *testing.T) {
	prefix := PendingPrefix("emails")
	key := PendingKey("emails", 2, 999, "job_xyz")
	if !bytes.HasPrefix(key, prefix) {
		t.Error("pending key should start with queue prefix")
	}

	// Different queue should NOT match.
	otherKey := PendingKey("sms", 2, 999, "job_xyz")
	if bytes.HasPrefix(otherKey, prefix) {
		t.Error("different queue should not match")
	}
}

func TestScheduledKeySortOrder(t *testing.T) {
	k1 := ScheduledKey("q", 1000, "job_a")
	k2 := ScheduledKey("q", 2000, "job_b")
	if bytes.Compare(k1, k2) >= 0 {
		t.Error("earlier scheduled_ns should sort first")
	}
}

func TestRetryingKeySortOrder(t *testing.T) {
	k1 := RetryingKey("q", 1000, "job_a")
	k2 := RetryingKey("q", 2000, "job_b")
	if bytes.Compare(k1, k2) >= 0 {
		t.Error("earlier retry_ns should sort first")
	}
}

func TestActiveKeyContainsJobID(t *testing.T) {
	k := ActiveKey("myqueue", "job_123")
	prefix := ActivePrefix("myqueue")
	if !bytes.HasPrefix(k, prefix) {
		t.Error("active key should start with queue prefix")
	}
	jobID := string(k[len(prefix):])
	if jobID != "job_123" {
		t.Errorf("job id: got %q, want %q", jobID, "job_123")
	}
}

func TestUniqueKeyValueRoundTrip(t *testing.T) {
	k := UniqueKey("emails", "dedup-key-1")
	prefix := UniquePrefix("emails")
	if !bytes.HasPrefix(k, prefix) {
		t.Error("unique key should start with queue prefix")
	}

	val := EncodeUniqueValue("job_XYZ", 1700000000000000000)
	jobID, expiresNs := DecodeUniqueValue(val)
	if jobID != "job_XYZ" {
		t.Errorf("jobID: got %q, want %q", jobID, "job_XYZ")
	}
	if expiresNs != 1700000000000000000 {
		t.Errorf("expiresNs: got %d, want %d", expiresNs, 1700000000000000000)
	}
}

func TestJobErrorKeyPrefix(t *testing.T) {
	prefix := JobErrorPrefix("job_ABC")
	k1 := JobErrorKey("job_ABC", 1)
	k2 := JobErrorKey("job_ABC", 2)

	if !bytes.HasPrefix(k1, prefix) {
		t.Error("error key 1 should start with prefix")
	}
	if !bytes.HasPrefix(k2, prefix) {
		t.Error("error key 2 should start with prefix")
	}
	if bytes.Compare(k1, k2) >= 0 {
		t.Error("attempt 1 should sort before attempt 2")
	}

	// Different job should not match.
	otherKey := JobErrorKey("job_DEF", 1)
	if bytes.HasPrefix(otherKey, prefix) {
		t.Error("different job error should not match prefix")
	}
}

func TestRateLimitKeySortByTime(t *testing.T) {
	k1 := RateLimitKey("q", 1000, 1)
	k2 := RateLimitKey("q", 2000, 1)
	if bytes.Compare(k1, k2) >= 0 {
		t.Error("earlier fetched_ns should sort first")
	}
}

func TestQueueConfigKey(t *testing.T) {
	k := QueueConfigKey("emails")
	if string(k) != "qc|emails" {
		t.Errorf("got %q", string(k))
	}
}

func TestQueueNameKey(t *testing.T) {
	k := QueueNameKey("emails")
	if string(k) != "qn|emails" {
		t.Errorf("got %q", string(k))
	}
}

func TestBatchKey(t *testing.T) {
	k := BatchKey("batch_123")
	if string(k) != "b|batch_123" {
		t.Errorf("got %q", string(k))
	}
}

func TestWorkerKey(t *testing.T) {
	k := WorkerKey("worker_1")
	if string(k) != "w|worker_1" {
		t.Errorf("got %q", string(k))
	}
}
