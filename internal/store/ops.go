package store

import (
	"encoding/json"
	"time"
)

// OpType identifies the Raft log operation.
type OpType uint8

const (
	OpEnqueue        OpType = 1
	OpEnqueueBatch   OpType = 2
	OpFetch          OpType = 3
	OpAck            OpType = 4
	OpFail           OpType = 5
	OpHeartbeat      OpType = 6
	OpRetryJob       OpType = 7
	OpCancelJob      OpType = 8
	OpMoveJob        OpType = 9
	OpDeleteJob      OpType = 10
	OpPauseQueue     OpType = 11
	OpResumeQueue    OpType = 12
	OpClearQueue     OpType = 13
	OpDeleteQueue    OpType = 14
	OpSetConcurrency OpType = 15
	OpSetThrottle    OpType = 16
	OpRemoveThrottle OpType = 17
	OpPromote        OpType = 18
	OpReclaim        OpType = 19
	OpBulkAction     OpType = 20
	OpCleanUnique    OpType = 21
	OpCleanRateLimit OpType = 22
	OpAckBatch       OpType = 23
	OpMulti          OpType = 24
	OpFetchBatch     OpType = 25
	OpSetBudget          OpType = 26
	OpDeleteBudget       OpType = 27
	OpSetProvider        OpType = 28
	OpDeleteProvider     OpType = 29
	OpSetQueueProvider   OpType = 30
)

// Op is the Raft log entry payload.
type Op struct {
	Type OpType          `json:"t"`
	Data json.RawMessage `json:"d"`
}

// MultiOp groups several operations into one Raft log entry.
type MultiOp struct {
	Ops []Op `json:"ops"`
}

// OpResult wraps the result of an FSM Apply.
type OpResult struct {
	Data any
	Err  error
}

// Applier submits operations to the Raft cluster.
type Applier interface {
	Apply(opType OpType, data any) *OpResult
}

// MarshalOp creates a serialized Op from type and data.
func MarshalOp(opType OpType, data any) ([]byte, error) {
	return encodeRaftOp(opType, data)
}

// DecodeRaftOp decodes a protobuf-encoded Raft log entry.
func DecodeRaftOp(data []byte) (*DecodedRaftOp, error) {
	return decodeRaftOp(data)
}

// MarshalMulti builds a protobuf MultiOp envelope directly from typed inputs.
func MarshalMulti(inputs []OpInput) ([]byte, error) {
	return MarshalMultiInputs(inputs)
}

// BuildOp creates an Op envelope from type and payload.
func BuildOp(opType OpType, data any) (Op, error) {
	d, err := json.Marshal(data)
	if err != nil {
		return Op{}, err
	}
	return Op{Type: opType, Data: d}, nil
}

// Pre-computed data structs for each operation.
// All timestamps are pre-computed by the leader (no time.Now() in FSM).

type EnqueueOp struct {
	JobID        string          `json:"job_id"`
	Queue        string          `json:"queue"`
	State        string          `json:"state"`
	Payload      json.RawMessage `json:"payload"`
	Checkpoint   json.RawMessage `json:"checkpoint,omitempty"`
	ResultSchema json.RawMessage `json:"result_schema,omitempty"`
	Priority     int             `json:"priority"`
	MaxRetries   int             `json:"max_retries"`
	Backoff      string          `json:"backoff"`
	BaseDelayMs  int             `json:"base_delay_ms"`
	MaxDelayMs   int             `json:"max_delay_ms"`
	UniqueKey    string          `json:"unique_key,omitempty"`
	UniquePeriod int             `json:"unique_period,omitempty"` // seconds
	Tags         json.RawMessage `json:"tags,omitempty"`
	ScheduledAt  *time.Time      `json:"scheduled_at,omitempty"`
	ExpireAt     *time.Time      `json:"expire_at,omitempty"`
	CreatedAt    time.Time       `json:"created_at"`
	NowNs        uint64          `json:"now_ns"`
	BatchID      string          `json:"batch_id,omitempty"`
	Agent        *AgentState     `json:"agent,omitempty"`
	ParentID     string          `json:"parent_id,omitempty"`
	ChainID      string          `json:"chain_id,omitempty"`
	ChainStep    *int            `json:"chain_step,omitempty"`
	ChainConfig  json.RawMessage `json:"chain_config,omitempty"`
	Routing      *RoutingConfig  `json:"routing,omitempty"`
}

type EnqueueBatchOp struct {
	Jobs    []EnqueueOp `json:"jobs"`
	BatchID string      `json:"batch_id,omitempty"`
	Batch   *BatchOp    `json:"batch,omitempty"`
}

type BatchOp struct {
	CallbackQueue   string          `json:"callback_queue"`
	CallbackPayload json.RawMessage `json:"callback_payload,omitempty"`
}

type FetchOp struct {
	Queues        []string `json:"queues"`
	WorkerID      string   `json:"worker_id"`
	Hostname      string   `json:"hostname"`
	LeaseDuration int      `json:"lease_duration"`
	NowNs         uint64   `json:"now_ns"`
	RandomSeed    uint64   `json:"random_seed"`
}

type FetchBatchOp struct {
	Queues        []string `json:"queues"`
	WorkerID      string   `json:"worker_id"`
	Hostname      string   `json:"hostname"`
	LeaseDuration int      `json:"lease_duration"`
	Count         int      `json:"count"`
	NowNs         uint64   `json:"now_ns"`
	RandomSeed    uint64   `json:"random_seed"`
}

type AckOp struct {
	JobID       string          `json:"job_id"`
	Result      json.RawMessage `json:"result,omitempty"`
	Checkpoint  json.RawMessage `json:"checkpoint,omitempty"`
	Trace       json.RawMessage `json:"trace,omitempty"`
	Usage       *UsageReport    `json:"usage,omitempty"`
	AgentStatus string          `json:"agent_status,omitempty"`
	HoldReason  string          `json:"hold_reason,omitempty"`
	NowNs       uint64          `json:"now_ns"`
}

type AckBatchOp struct {
	Acks  []AckOp `json:"acks"`
	NowNs uint64  `json:"now_ns"`
}

type FailOp struct {
	JobID         string `json:"job_id"`
	Error         string `json:"error"`
	Backtrace     string `json:"backtrace,omitempty"`
	ProviderError bool   `json:"provider_error,omitempty"`
	NowNs         uint64 `json:"now_ns"`
}

type HeartbeatOp struct {
	Jobs  map[string]HeartbeatJobOp `json:"jobs"`
	NowNs uint64                    `json:"now_ns"`
}

type HeartbeatJobOp struct {
	Progress    json.RawMessage `json:"progress,omitempty"`
	Checkpoint  json.RawMessage `json:"checkpoint,omitempty"`
	StreamDelta string          `json:"stream_delta,omitempty"`
	Usage       *UsageReport    `json:"usage,omitempty"`
}

type RetryJobOp struct {
	JobID string `json:"job_id"`
	NowNs uint64 `json:"now_ns"`
}

type CancelJobOp struct {
	JobID string `json:"job_id"`
	NowNs uint64 `json:"now_ns"`
}

type MoveJobOp struct {
	JobID       string `json:"job_id"`
	TargetQueue string `json:"target_queue"`
	NowNs       uint64 `json:"now_ns"`
}

type DeleteJobOp struct {
	JobID string `json:"job_id"`
}

type QueueOp struct {
	Queue string `json:"queue"`
}

type SetConcurrencyOp struct {
	Queue string `json:"queue"`
	Max   int    `json:"max"`
}

type SetThrottleOp struct {
	Queue    string `json:"queue"`
	Rate     int    `json:"rate"`
	WindowMs int    `json:"window_ms"`
}

type PromoteOp struct {
	NowNs uint64 `json:"now_ns"`
}

type ReclaimOp struct {
	NowNs uint64 `json:"now_ns"`
}

type BulkActionOp struct {
	JobIDs      []string `json:"job_ids"`
	Action      string   `json:"action"`
	MoveToQueue string   `json:"move_to_queue,omitempty"`
	Priority    int      `json:"priority,omitempty"`
	NowNs       uint64   `json:"now_ns"`
}

type CleanUniqueOp struct {
	NowNs uint64 `json:"now_ns"`
}

type CleanRateLimitOp struct {
	CutoffNs uint64 `json:"cutoff_ns"`
}

type SetBudgetOp struct {
	ID        string   `json:"id"`
	Scope     string   `json:"scope"`
	Target    string   `json:"target"`
	DailyUSD  *float64 `json:"daily_usd,omitempty"`
	PerJobUSD *float64 `json:"per_job_usd,omitempty"`
	OnExceed  string   `json:"on_exceed"`
	CreatedAt string   `json:"created_at"`
}

type DeleteBudgetOp struct {
	Scope  string `json:"scope"`
	Target string `json:"target"`
}

type SetProviderOp struct {
	Name           string `json:"name"`
	RPMLimit       *int   `json:"rpm_limit,omitempty"`
	InputTPMLimit  *int   `json:"input_tpm_limit,omitempty"`
	OutputTPMLimit *int   `json:"output_tpm_limit,omitempty"`
	CreatedAt      string `json:"created_at"`
}

type DeleteProviderOp struct {
	Name string `json:"name"`
}

type SetQueueProviderOp struct {
	Queue    string `json:"queue"`
	Provider string `json:"provider"`
}
