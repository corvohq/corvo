package kv

import "testing"

func TestPutGetUint32BE(t *testing.T) {
	tests := []uint32{0, 1, 255, 256, 65535, 1<<32 - 1}
	for _, v := range tests {
		b := PutUint32BE(nil, v)
		if len(b) != 4 {
			t.Fatalf("PutUint32BE: expected 4 bytes, got %d", len(b))
		}
		got := GetUint32BE(b)
		if got != v {
			t.Errorf("round-trip %d: got %d", v, got)
		}
	}
}

func TestPutGetUint64BE(t *testing.T) {
	tests := []uint64{0, 1, 1<<32 - 1, 1 << 32, 1<<63 - 1, 1<<64 - 1}
	for _, v := range tests {
		b := PutUint64BE(nil, v)
		if len(b) != 8 {
			t.Fatalf("PutUint64BE: expected 8 bytes, got %d", len(b))
		}
		got := GetUint64BE(b)
		if got != v {
			t.Errorf("round-trip %d: got %d", v, got)
		}
	}
}

func TestUint64BESortOrder(t *testing.T) {
	// Big-endian encoding must sort numerically via byte comparison.
	vals := []uint64{0, 1, 100, 1000, 1<<32 - 1, 1 << 32, 1<<64 - 1}
	for i := 1; i < len(vals); i++ {
		a := PutUint64BE(nil, vals[i-1])
		b := PutUint64BE(nil, vals[i])
		if string(a) >= string(b) {
			t.Errorf("sort order violated: %d >= %d in bytes", vals[i-1], vals[i])
		}
	}
}
