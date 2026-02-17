package store

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestBinaryCodecFetchBatchRoundTrip(t *testing.T) {
	tests := []struct {
		name string
		op   FetchBatchOp
	}{
		{
			name: "basic",
			op: FetchBatchOp{
				Queues:        []string{"default", "critical"},
				WorkerID:      "worker-1",
				Hostname:      "host-1",
				LeaseDuration: 30,
				Count:         5,
				NowNs:         1234567890,
				RandomSeed:    9876543210,
			},
		},
		{
			name: "with candidates",
			op: FetchBatchOp{
				Queues:          []string{"q1"},
				WorkerID:        "w1",
				Hostname:        "h1",
				LeaseDuration:   60,
				Count:           10,
				NowNs:           11111111111,
				RandomSeed:      22222222222,
				CandidateJobIDs: []string{"job-a", "job-b", "job-c"},
				CandidateQueues: []string{"q1", "q1", "q1"},
			},
		},
		{
			name: "empty queues",
			op: FetchBatchOp{
				WorkerID:      "w1",
				Hostname:      "h1",
				LeaseDuration: 10,
				Count:         1,
				NowNs:         100,
				RandomSeed:    200,
			},
		},
		{
			name: "empty strings",
			op: FetchBatchOp{
				Queues:        []string{""},
				LeaseDuration: 0,
				Count:         0,
				NowNs:         0,
				RandomSeed:    0,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			inputs := []OpInput{{Type: OpFetchBatch, Data: tt.op}}
			encoded, err := marshalMultiBinary(inputs)
			if err != nil {
				t.Fatalf("marshalMultiBinary: %v", err)
			}

			decoded, err := decodeMultiBinary(encoded)
			if err != nil {
				t.Fatalf("decodeMultiBinary: %v", err)
			}

			if decoded.Type != OpMulti {
				t.Fatalf("expected OpMulti, got %d", decoded.Type)
			}
			if len(decoded.Multi) != 1 {
				t.Fatalf("expected 1 op, got %d", len(decoded.Multi))
			}
			got := decoded.Multi[0]
			if got.Type != OpFetchBatch {
				t.Fatalf("expected OpFetchBatch, got %d", got.Type)
			}
			if got.FetchBatch == nil {
				t.Fatal("FetchBatch is nil")
			}
			if !reflect.DeepEqual(*got.FetchBatch, tt.op) {
				t.Fatalf("mismatch:\ngot:  %+v\nwant: %+v", *got.FetchBatch, tt.op)
			}
		})
	}
}

func TestBinaryCodecAckBatchRoundTrip(t *testing.T) {
	tests := []struct {
		name string
		op   AckBatchOp
	}{
		{
			name: "basic single ack",
			op: AckBatchOp{
				NowNs: 9999999,
				Acks: []AckOp{
					{
						JobID: "job-1",
						NowNs: 9999999,
					},
				},
			},
		},
		{
			name: "with result and checkpoint",
			op: AckBatchOp{
				NowNs: 100,
				Acks: []AckOp{
					{
						JobID:      "job-2",
						Result:     json.RawMessage(`{"status":"ok"}`),
						Checkpoint: json.RawMessage(`{"step":3}`),
						NowNs:      100,
					},
				},
			},
		},
		{
			name: "with usage report",
			op: AckBatchOp{
				NowNs: 200,
				Acks: []AckOp{
					{
						JobID: "job-3",
						NowNs: 200,
						Usage: &UsageReport{
							InputTokens:         1000,
							OutputTokens:         500,
							CacheCreationTokens: 100,
							CacheReadTokens:     50,
							Model:               "claude-3",
							Provider:            "anthropic",
							CostUSD:             0.0042,
						},
					},
				},
			},
		},
		{
			name: "with agent fields",
			op: AckBatchOp{
				NowNs: 300,
				Acks: []AckOp{
					{
						JobID:       "job-4",
						NowNs:       300,
						AgentStatus: "running",
						HoldReason:  "waiting",
						StepStatus:  "step-1-done",
						ExitReason:  "completed",
					},
				},
			},
		},
		{
			name: "multiple acks",
			op: AckBatchOp{
				NowNs: 400,
				Acks: []AckOp{
					{JobID: "job-a", NowNs: 400},
					{JobID: "job-b", NowNs: 401, Result: json.RawMessage(`"done"`)},
					{
						JobID: "job-c",
						NowNs: 402,
						Usage: &UsageReport{
							InputTokens:  10,
							OutputTokens: 20,
							CostUSD:      0.001,
						},
					},
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			inputs := []OpInput{{Type: OpAckBatch, Data: tt.op}}
			encoded, err := marshalMultiBinary(inputs)
			if err != nil {
				t.Fatalf("marshalMultiBinary: %v", err)
			}

			decoded, err := decodeMultiBinary(encoded)
			if err != nil {
				t.Fatalf("decodeMultiBinary: %v", err)
			}

			if decoded.Type != OpMulti {
				t.Fatalf("expected OpMulti, got %d", decoded.Type)
			}
			if len(decoded.Multi) != 1 {
				t.Fatalf("expected 1 op, got %d", len(decoded.Multi))
			}
			got := decoded.Multi[0]
			if got.Type != OpAckBatch {
				t.Fatalf("expected OpAckBatch, got %d", got.Type)
			}
			if got.AckBatch == nil {
				t.Fatal("AckBatch is nil")
			}
			if !reflect.DeepEqual(*got.AckBatch, tt.op) {
				t.Fatalf("mismatch:\ngot:  %+v\nwant: %+v", *got.AckBatch, tt.op)
			}
		})
	}
}

func TestBinaryCodecMixedOps(t *testing.T) {
	inputs := []OpInput{
		{Type: OpFetchBatch, Data: FetchBatchOp{
			Queues:        []string{"default"},
			WorkerID:      "w1",
			Hostname:      "h1",
			LeaseDuration: 30,
			Count:         5,
			NowNs:         111,
			RandomSeed:    222,
		}},
		{Type: OpAckBatch, Data: AckBatchOp{
			NowNs: 333,
			Acks: []AckOp{
				{JobID: "job-1", NowNs: 333},
			},
		}},
	}

	encoded, err := marshalMultiBinary(inputs)
	if err != nil {
		t.Fatalf("marshalMultiBinary: %v", err)
	}

	decoded, err := decodeMultiBinary(encoded)
	if err != nil {
		t.Fatalf("decodeMultiBinary: %v", err)
	}

	if len(decoded.Multi) != 2 {
		t.Fatalf("expected 2 ops, got %d", len(decoded.Multi))
	}
	if decoded.Multi[0].Type != OpFetchBatch {
		t.Fatalf("expected OpFetchBatch, got %d", decoded.Multi[0].Type)
	}
	if decoded.Multi[1].Type != OpAckBatch {
		t.Fatalf("expected OpAckBatch, got %d", decoded.Multi[1].Type)
	}
}

func TestBinaryCodecViaPublicAPI(t *testing.T) {
	inputs := []OpInput{
		{Type: OpFetchBatch, Data: FetchBatchOp{
			Queues:        []string{"default"},
			WorkerID:      "w1",
			Hostname:      "h1",
			LeaseDuration: 30,
			Count:         1,
			NowNs:         555,
			RandomSeed:    666,
		}},
	}

	encoded, err := MarshalMulti(inputs)
	if err != nil {
		t.Fatalf("MarshalMulti: %v", err)
	}

	decoded, err := DecodeRaftOp(encoded)
	if err != nil {
		t.Fatalf("DecodeRaftOp: %v", err)
	}

	if decoded.Type != OpMulti {
		t.Fatalf("expected OpMulti, got %d", decoded.Type)
	}
	if len(decoded.Multi) != 1 {
		t.Fatalf("expected 1 op, got %d", len(decoded.Multi))
	}
	if decoded.Multi[0].FetchBatch == nil {
		t.Fatal("FetchBatch is nil")
	}
	if decoded.Multi[0].FetchBatch.WorkerID != "w1" {
		t.Fatalf("expected WorkerID w1, got %s", decoded.Multi[0].FetchBatch.WorkerID)
	}
}

func TestBinaryCodecFallbackProtobuf(t *testing.T) {
	inputs := []OpInput{
		{Type: OpFetchBatch, Data: FetchBatchOp{
			Queues:   []string{"q1"},
			WorkerID: "w1",
			Hostname: "h1",
			NowNs:    100,
		}},
		{Type: OpPromote, Data: PromoteOp{NowNs: 200}},
	}

	encoded, err := MarshalMulti(inputs)
	if err != nil {
		t.Fatalf("MarshalMulti: %v", err)
	}

	decoded, err := DecodeRaftOp(encoded)
	if err != nil {
		t.Fatalf("DecodeRaftOp: %v", err)
	}

	if len(decoded.Multi) != 2 {
		t.Fatalf("expected 2 ops, got %d", len(decoded.Multi))
	}
	if decoded.Multi[0].Type != OpFetchBatch {
		t.Fatalf("expected OpFetchBatch, got %d", decoded.Multi[0].Type)
	}
	if decoded.Multi[1].Type != OpPromote {
		t.Fatalf("expected OpPromote, got %d", decoded.Multi[1].Type)
	}
	if decoded.Multi[1].Promote == nil {
		t.Fatal("Promote is nil")
	}
	if decoded.Multi[1].Promote.NowNs != 200 {
		t.Fatalf("expected NowNs 200, got %d", decoded.Multi[1].Promote.NowNs)
	}
}
