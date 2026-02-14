package store

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	oldproto "github.com/golang/protobuf/proto"
)

var raftProtoPrefix = []byte{0x50, 0x42, 0x31} // "PB1"

// DecodedRaftOp is a wire-decoded operation for FSM dispatch.
type DecodedRaftOp struct {
	Type         OpType
	Enqueue      *EnqueueOp
	EnqueueBatch *EnqueueBatchOp
	Fetch        *FetchOp
	FetchBatch   *FetchBatchOp
	Ack          *AckOp
	AckBatch     *AckBatchOp
	Fail         *FailOp
	Heartbeat    *HeartbeatOp
	RetryJob     *RetryJobOp
	CancelJob    *CancelJobOp
	MoveJob      *MoveJobOp
	DeleteJob    *DeleteJobOp
	PauseQueue   *QueueOp
	ResumeQueue  *QueueOp
	ClearQueue   *QueueOp
	DeleteQueue  *QueueOp
	SetConc      *SetConcurrencyOp
	SetThrottle  *SetThrottleOp
	RemoveThr    *QueueOp
	Promote      *PromoteOp
	Reclaim      *ReclaimOp
	BulkAction   *BulkActionOp
	CleanUnique  *CleanUniqueOp
	CleanRate    *CleanRateLimitOp
	SetBudget    *SetBudgetOp
	DeleteBudget *DeleteBudgetOp
	SetProvider      *SetProviderOp
	DeleteProvider   *DeleteProviderOp
	SetQueueProvider *SetQueueProviderOp
	Multi        []*DecodedRaftOp
}

// OpInput is a typed operation used for batched protobuf encoding.
type OpInput struct {
	Type OpType
	Data any
}

type pbOp struct {
	Type         uint32            `protobuf:"varint,1,opt,name=type,proto3" json:"type,omitempty"`
	Enqueue      *pbEnqueueOp      `protobuf:"bytes,2,opt,name=enqueue,proto3" json:"enqueue,omitempty"`
	EnqueueBatch *pbEnqueueBatchOp `protobuf:"bytes,3,opt,name=enqueue_batch,json=enqueueBatch,proto3" json:"enqueue_batch,omitempty"`
	Multi        *pbMultiOp        `protobuf:"bytes,4,opt,name=multi,proto3" json:"multi,omitempty"`
	Fetch        *pbFetchOp        `protobuf:"bytes,5,opt,name=fetch,proto3" json:"fetch,omitempty"`
	FetchBatch   *pbFetchBatchOp   `protobuf:"bytes,6,opt,name=fetch_batch,json=fetchBatch,proto3" json:"fetch_batch,omitempty"`
	Ack          *pbAckOp          `protobuf:"bytes,7,opt,name=ack,proto3" json:"ack,omitempty"`
	AckBatch     *pbAckBatchOp     `protobuf:"bytes,8,opt,name=ack_batch,json=ackBatch,proto3" json:"ack_batch,omitempty"`
	Fail         *pbFailOp         `protobuf:"bytes,9,opt,name=fail,proto3" json:"fail,omitempty"`
	Heartbeat    *pbHeartbeatOp    `protobuf:"bytes,10,opt,name=heartbeat,proto3" json:"heartbeat,omitempty"`
	RetryJob     *pbRetryJobOp     `protobuf:"bytes,11,opt,name=retry_job,json=retryJob,proto3" json:"retry_job,omitempty"`
	CancelJob    *pbCancelJobOp    `protobuf:"bytes,12,opt,name=cancel_job,json=cancelJob,proto3" json:"cancel_job,omitempty"`
	MoveJob      *pbMoveJobOp      `protobuf:"bytes,13,opt,name=move_job,json=moveJob,proto3" json:"move_job,omitempty"`
	DeleteJob    *pbDeleteJobOp    `protobuf:"bytes,14,opt,name=delete_job,json=deleteJob,proto3" json:"delete_job,omitempty"`
	PauseQueue   *pbQueueOp        `protobuf:"bytes,15,opt,name=pause_queue,json=pauseQueue,proto3" json:"pause_queue,omitempty"`
	ResumeQueue  *pbQueueOp        `protobuf:"bytes,16,opt,name=resume_queue,json=resumeQueue,proto3" json:"resume_queue,omitempty"`
	ClearQueue   *pbQueueOp        `protobuf:"bytes,17,opt,name=clear_queue,json=clearQueue,proto3" json:"clear_queue,omitempty"`
	DeleteQueue  *pbQueueOp        `protobuf:"bytes,18,opt,name=delete_queue,json=deleteQueue,proto3" json:"delete_queue,omitempty"`
	SetConc      *pbSetConcOp      `protobuf:"bytes,19,opt,name=set_conc,json=setConc,proto3" json:"set_conc,omitempty"`
	SetThrottle  *pbSetThrottleOp  `protobuf:"bytes,20,opt,name=set_throttle,json=setThrottle,proto3" json:"set_throttle,omitempty"`
	RemoveThr    *pbQueueOp        `protobuf:"bytes,21,opt,name=remove_thr,json=removeThr,proto3" json:"remove_thr,omitempty"`
	Promote      *pbPromoteOp      `protobuf:"bytes,22,opt,name=promote,proto3" json:"promote,omitempty"`
	Reclaim      *pbReclaimOp      `protobuf:"bytes,23,opt,name=reclaim,proto3" json:"reclaim,omitempty"`
	BulkAction   *pbBulkActionOp   `protobuf:"bytes,24,opt,name=bulk_action,json=bulkAction,proto3" json:"bulk_action,omitempty"`
	CleanUnique  *pbCleanUniqueOp  `protobuf:"bytes,25,opt,name=clean_unique,json=cleanUnique,proto3" json:"clean_unique,omitempty"`
	CleanRate    *pbCleanRateOp    `protobuf:"bytes,26,opt,name=clean_rate,json=cleanRate,proto3" json:"clean_rate,omitempty"`
	SetBudget        *pbSetBudgetOp        `protobuf:"bytes,27,opt,name=set_budget,json=setBudget,proto3" json:"set_budget,omitempty"`
	DeleteBudget     *pbDeleteBudgetOp     `protobuf:"bytes,28,opt,name=delete_budget,json=deleteBudget,proto3" json:"delete_budget,omitempty"`
	SetProvider      *pbSetProviderOp      `protobuf:"bytes,29,opt,name=set_provider,json=setProvider,proto3" json:"set_provider,omitempty"`
	DeleteProvider   *pbDeleteProviderOp   `protobuf:"bytes,30,opt,name=delete_provider,json=deleteProvider,proto3" json:"delete_provider,omitempty"`
	SetQueueProvider *pbSetQueueProviderOp `protobuf:"bytes,31,opt,name=set_queue_provider,json=setQueueProvider,proto3" json:"set_queue_provider,omitempty"`
}

func (m *pbOp) Reset()         { *m = pbOp{} }
func (m *pbOp) String() string { return oldproto.CompactTextString(m) }
func (*pbOp) ProtoMessage()    {}

type pbMultiOp struct {
	Ops []*pbOp `protobuf:"bytes,1,rep,name=ops,proto3" json:"ops,omitempty"`
}

func (m *pbMultiOp) Reset()         { *m = pbMultiOp{} }
func (m *pbMultiOp) String() string { return oldproto.CompactTextString(m) }
func (*pbMultiOp) ProtoMessage()    {}

type pbEnqueueOp struct {
	JobID                 string  `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	Queue                 string  `protobuf:"bytes,2,opt,name=queue,proto3" json:"queue,omitempty"`
	State                 string  `protobuf:"bytes,3,opt,name=state,proto3" json:"state,omitempty"`
	Payload               []byte  `protobuf:"bytes,4,opt,name=payload,proto3" json:"payload,omitempty"`
	Priority              int32   `protobuf:"varint,5,opt,name=priority,proto3" json:"priority,omitempty"`
	MaxRetries            int32   `protobuf:"varint,6,opt,name=max_retries,json=maxRetries,proto3" json:"max_retries,omitempty"`
	Backoff               string  `protobuf:"bytes,7,opt,name=backoff,proto3" json:"backoff,omitempty"`
	BaseDelayMs           int32   `protobuf:"varint,8,opt,name=base_delay_ms,json=baseDelayMs,proto3" json:"base_delay_ms,omitempty"`
	MaxDelayMs            int32   `protobuf:"varint,9,opt,name=max_delay_ms,json=maxDelayMs,proto3" json:"max_delay_ms,omitempty"`
	UniqueKey             string  `protobuf:"bytes,10,opt,name=unique_key,json=uniqueKey,proto3" json:"unique_key,omitempty"`
	UniquePeriod          int32   `protobuf:"varint,11,opt,name=unique_period,json=uniquePeriod,proto3" json:"unique_period,omitempty"`
	Tags                  []byte  `protobuf:"bytes,12,opt,name=tags,proto3" json:"tags,omitempty"`
	ScheduledAtNs         int64   `protobuf:"varint,13,opt,name=scheduled_at_ns,json=scheduledAtNs,proto3" json:"scheduled_at_ns,omitempty"`
	HasScheduledAt        bool    `protobuf:"varint,14,opt,name=has_scheduled_at,json=hasScheduledAt,proto3" json:"has_scheduled_at,omitempty"`
	ExpireAtNs            int64   `protobuf:"varint,15,opt,name=expire_at_ns,json=expireAtNs,proto3" json:"expire_at_ns,omitempty"`
	HasExpireAt           bool    `protobuf:"varint,16,opt,name=has_expire_at,json=hasExpireAt,proto3" json:"has_expire_at,omitempty"`
	CreatedAtNs           int64   `protobuf:"varint,17,opt,name=created_at_ns,json=createdAtNs,proto3" json:"created_at_ns,omitempty"`
	NowNs                 uint64  `protobuf:"varint,18,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
	BatchID               string  `protobuf:"bytes,19,opt,name=batch_id,json=batchId,proto3" json:"batch_id,omitempty"`
	Checkpoint            []byte  `protobuf:"bytes,20,opt,name=checkpoint,proto3" json:"checkpoint,omitempty"`
	AgentMaxIterations    int32   `protobuf:"varint,21,opt,name=agent_max_iterations,json=agentMaxIterations,proto3" json:"agent_max_iterations,omitempty"`
	AgentMaxCostUsd       float64 `protobuf:"fixed64,22,opt,name=agent_max_cost_usd,json=agentMaxCostUsd,proto3" json:"agent_max_cost_usd,omitempty"`
	AgentIterationTimeout string  `protobuf:"bytes,23,opt,name=agent_iteration_timeout,json=agentIterationTimeout,proto3" json:"agent_iteration_timeout,omitempty"`
	AgentIteration        int32   `protobuf:"varint,24,opt,name=agent_iteration,json=agentIteration,proto3" json:"agent_iteration,omitempty"`
	AgentTotalCostUsd     float64 `protobuf:"fixed64,25,opt,name=agent_total_cost_usd,json=agentTotalCostUsd,proto3" json:"agent_total_cost_usd,omitempty"`
	HasAgent              bool    `protobuf:"varint,26,opt,name=has_agent,json=hasAgent,proto3" json:"has_agent,omitempty"`
	ResultSchema          []byte  `protobuf:"bytes,27,opt,name=result_schema,json=resultSchema,proto3" json:"result_schema,omitempty"`
	ParentID              string  `protobuf:"bytes,28,opt,name=parent_id,json=parentId,proto3" json:"parent_id,omitempty"`
	ChainID               string  `protobuf:"bytes,29,opt,name=chain_id,json=chainId,proto3" json:"chain_id,omitempty"`
	ChainStep             int32   `protobuf:"varint,30,opt,name=chain_step,json=chainStep,proto3" json:"chain_step,omitempty"`
	HasChainStep          bool    `protobuf:"varint,31,opt,name=has_chain_step,json=hasChainStep,proto3" json:"has_chain_step,omitempty"`
	ChainConfig           []byte  `protobuf:"bytes,32,opt,name=chain_config,json=chainConfig,proto3" json:"chain_config,omitempty"`
	Routing               []byte  `protobuf:"bytes,33,opt,name=routing,proto3" json:"routing,omitempty"`
}

func (m *pbEnqueueOp) Reset()         { *m = pbEnqueueOp{} }
func (m *pbEnqueueOp) String() string { return oldproto.CompactTextString(m) }
func (*pbEnqueueOp) ProtoMessage()    {}

type pbBatchOp struct {
	CallbackQueue   string `protobuf:"bytes,1,opt,name=callback_queue,json=callbackQueue,proto3" json:"callback_queue,omitempty"`
	CallbackPayload []byte `protobuf:"bytes,2,opt,name=callback_payload,json=callbackPayload,proto3" json:"callback_payload,omitempty"`
}

func (m *pbBatchOp) Reset()         { *m = pbBatchOp{} }
func (m *pbBatchOp) String() string { return oldproto.CompactTextString(m) }
func (*pbBatchOp) ProtoMessage()    {}

type pbEnqueueBatchOp struct {
	Jobs    []*pbEnqueueOp `protobuf:"bytes,1,rep,name=jobs,proto3" json:"jobs,omitempty"`
	BatchID string         `protobuf:"bytes,2,opt,name=batch_id,json=batchId,proto3" json:"batch_id,omitempty"`
	Batch   *pbBatchOp     `protobuf:"bytes,3,opt,name=batch,proto3" json:"batch,omitempty"`
}

func (m *pbEnqueueBatchOp) Reset()         { *m = pbEnqueueBatchOp{} }
func (m *pbEnqueueBatchOp) String() string { return oldproto.CompactTextString(m) }
func (*pbEnqueueBatchOp) ProtoMessage()    {}

type pbFetchOp struct {
	Queues        []string `protobuf:"bytes,1,rep,name=queues,proto3" json:"queues,omitempty"`
	WorkerID      string   `protobuf:"bytes,2,opt,name=worker_id,json=workerId,proto3" json:"worker_id,omitempty"`
	Hostname      string   `protobuf:"bytes,3,opt,name=hostname,proto3" json:"hostname,omitempty"`
	LeaseDuration int32    `protobuf:"varint,4,opt,name=lease_duration,json=leaseDuration,proto3" json:"lease_duration,omitempty"`
	NowNs         uint64   `protobuf:"varint,5,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
	RandomSeed    uint64   `protobuf:"varint,6,opt,name=random_seed,json=randomSeed,proto3" json:"random_seed,omitempty"`
}

func (m *pbFetchOp) Reset()         { *m = pbFetchOp{} }
func (m *pbFetchOp) String() string { return oldproto.CompactTextString(m) }
func (*pbFetchOp) ProtoMessage()    {}

type pbFetchBatchOp struct {
	Queues        []string `protobuf:"bytes,1,rep,name=queues,proto3" json:"queues,omitempty"`
	WorkerID      string   `protobuf:"bytes,2,opt,name=worker_id,json=workerId,proto3" json:"worker_id,omitempty"`
	Hostname      string   `protobuf:"bytes,3,opt,name=hostname,proto3" json:"hostname,omitempty"`
	LeaseDuration int32    `protobuf:"varint,4,opt,name=lease_duration,json=leaseDuration,proto3" json:"lease_duration,omitempty"`
	Count         int32    `protobuf:"varint,5,opt,name=count,proto3" json:"count,omitempty"`
	NowNs         uint64   `protobuf:"varint,6,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
	RandomSeed    uint64   `protobuf:"varint,7,opt,name=random_seed,json=randomSeed,proto3" json:"random_seed,omitempty"`
}

func (m *pbFetchBatchOp) Reset()         { *m = pbFetchBatchOp{} }
func (m *pbFetchBatchOp) String() string { return oldproto.CompactTextString(m) }
func (*pbFetchBatchOp) ProtoMessage()    {}

type pbAckOp struct {
	JobID       string         `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	Result      []byte         `protobuf:"bytes,2,opt,name=result,proto3" json:"result,omitempty"`
	Usage       *pbUsageReport `protobuf:"bytes,3,opt,name=usage,proto3" json:"usage,omitempty"`
	NowNs       uint64         `protobuf:"varint,4,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
	Checkpoint  []byte         `protobuf:"bytes,5,opt,name=checkpoint,proto3" json:"checkpoint,omitempty"`
	AgentStatus string         `protobuf:"bytes,6,opt,name=agent_status,json=agentStatus,proto3" json:"agent_status,omitempty"`
	HoldReason  string         `protobuf:"bytes,7,opt,name=hold_reason,json=holdReason,proto3" json:"hold_reason,omitempty"`
	Trace       []byte         `protobuf:"bytes,8,opt,name=trace,proto3" json:"trace,omitempty"`
}

func (m *pbAckOp) Reset()         { *m = pbAckOp{} }
func (m *pbAckOp) String() string { return oldproto.CompactTextString(m) }
func (*pbAckOp) ProtoMessage()    {}

type pbAckBatchOp struct {
	Acks  []*pbAckOp `protobuf:"bytes,1,rep,name=acks,proto3" json:"acks,omitempty"`
	NowNs uint64     `protobuf:"varint,2,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbAckBatchOp) Reset()         { *m = pbAckBatchOp{} }
func (m *pbAckBatchOp) String() string { return oldproto.CompactTextString(m) }
func (*pbAckBatchOp) ProtoMessage()    {}

type pbFailOp struct {
	JobID         string `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	Error         string `protobuf:"bytes,2,opt,name=error,proto3" json:"error,omitempty"`
	Backtrace     string `protobuf:"bytes,3,opt,name=backtrace,proto3" json:"backtrace,omitempty"`
	NowNs         uint64 `protobuf:"varint,4,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
	ProviderError bool   `protobuf:"varint,5,opt,name=provider_error,json=providerError,proto3" json:"provider_error,omitempty"`
}

func (m *pbFailOp) Reset()         { *m = pbFailOp{} }
func (m *pbFailOp) String() string { return oldproto.CompactTextString(m) }
func (*pbFailOp) ProtoMessage()    {}

type pbHeartbeatJob struct {
	JobID       string         `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	Progress    []byte         `protobuf:"bytes,2,opt,name=progress,proto3" json:"progress,omitempty"`
	Checkpoint  []byte         `protobuf:"bytes,3,opt,name=checkpoint,proto3" json:"checkpoint,omitempty"`
	HasProgress bool           `protobuf:"varint,4,opt,name=has_progress,json=hasProgress,proto3" json:"has_progress,omitempty"`
	HasCP       bool           `protobuf:"varint,5,opt,name=has_cp,json=hasCp,proto3" json:"has_cp,omitempty"`
	Usage       *pbUsageReport `protobuf:"bytes,6,opt,name=usage,proto3" json:"usage,omitempty"`
	StreamDelta string         `protobuf:"bytes,7,opt,name=stream_delta,json=streamDelta,proto3" json:"stream_delta,omitempty"`
}

func (m *pbHeartbeatJob) Reset()         { *m = pbHeartbeatJob{} }
func (m *pbHeartbeatJob) String() string { return oldproto.CompactTextString(m) }
func (*pbHeartbeatJob) ProtoMessage()    {}

type pbHeartbeatOp struct {
	Jobs  []*pbHeartbeatJob `protobuf:"bytes,1,rep,name=jobs,proto3" json:"jobs,omitempty"`
	NowNs uint64            `protobuf:"varint,2,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbHeartbeatOp) Reset()         { *m = pbHeartbeatOp{} }
func (m *pbHeartbeatOp) String() string { return oldproto.CompactTextString(m) }
func (*pbHeartbeatOp) ProtoMessage()    {}

type pbUsageReport struct {
	InputTokens         int64   `protobuf:"varint,1,opt,name=input_tokens,json=inputTokens,proto3" json:"input_tokens,omitempty"`
	OutputTokens        int64   `protobuf:"varint,2,opt,name=output_tokens,json=outputTokens,proto3" json:"output_tokens,omitempty"`
	CacheCreationTokens int64   `protobuf:"varint,3,opt,name=cache_creation_tokens,json=cacheCreationTokens,proto3" json:"cache_creation_tokens,omitempty"`
	CacheReadTokens     int64   `protobuf:"varint,4,opt,name=cache_read_tokens,json=cacheReadTokens,proto3" json:"cache_read_tokens,omitempty"`
	Model               string  `protobuf:"bytes,5,opt,name=model,proto3" json:"model,omitempty"`
	Provider            string  `protobuf:"bytes,6,opt,name=provider,proto3" json:"provider,omitempty"`
	CostUsd             float64 `protobuf:"fixed64,7,opt,name=cost_usd,json=costUsd,proto3" json:"cost_usd,omitempty"`
}

func (m *pbUsageReport) Reset()         { *m = pbUsageReport{} }
func (m *pbUsageReport) String() string { return oldproto.CompactTextString(m) }
func (*pbUsageReport) ProtoMessage()    {}

type pbRetryJobOp struct {
	JobID string `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	NowNs uint64 `protobuf:"varint,2,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbRetryJobOp) Reset()         { *m = pbRetryJobOp{} }
func (m *pbRetryJobOp) String() string { return oldproto.CompactTextString(m) }
func (*pbRetryJobOp) ProtoMessage()    {}

type pbCancelJobOp struct {
	JobID string `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	NowNs uint64 `protobuf:"varint,2,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbCancelJobOp) Reset()         { *m = pbCancelJobOp{} }
func (m *pbCancelJobOp) String() string { return oldproto.CompactTextString(m) }
func (*pbCancelJobOp) ProtoMessage()    {}

type pbMoveJobOp struct {
	JobID       string `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
	TargetQueue string `protobuf:"bytes,2,opt,name=target_queue,json=targetQueue,proto3" json:"target_queue,omitempty"`
	NowNs       uint64 `protobuf:"varint,3,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbMoveJobOp) Reset()         { *m = pbMoveJobOp{} }
func (m *pbMoveJobOp) String() string { return oldproto.CompactTextString(m) }
func (*pbMoveJobOp) ProtoMessage()    {}

type pbDeleteJobOp struct {
	JobID string `protobuf:"bytes,1,opt,name=job_id,json=jobId,proto3" json:"job_id,omitempty"`
}

func (m *pbDeleteJobOp) Reset()         { *m = pbDeleteJobOp{} }
func (m *pbDeleteJobOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteJobOp) ProtoMessage()    {}

type pbQueueOp struct {
	Queue string `protobuf:"bytes,1,opt,name=queue,proto3" json:"queue,omitempty"`
}

func (m *pbQueueOp) Reset()         { *m = pbQueueOp{} }
func (m *pbQueueOp) String() string { return oldproto.CompactTextString(m) }
func (*pbQueueOp) ProtoMessage()    {}

type pbSetConcOp struct {
	Queue string `protobuf:"bytes,1,opt,name=queue,proto3" json:"queue,omitempty"`
	Max   int32  `protobuf:"varint,2,opt,name=max,proto3" json:"max,omitempty"`
}

func (m *pbSetConcOp) Reset()         { *m = pbSetConcOp{} }
func (m *pbSetConcOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetConcOp) ProtoMessage()    {}

type pbSetThrottleOp struct {
	Queue    string `protobuf:"bytes,1,opt,name=queue,proto3" json:"queue,omitempty"`
	Rate     int32  `protobuf:"varint,2,opt,name=rate,proto3" json:"rate,omitempty"`
	WindowMs int32  `protobuf:"varint,3,opt,name=window_ms,json=windowMs,proto3" json:"window_ms,omitempty"`
}

func (m *pbSetThrottleOp) Reset()         { *m = pbSetThrottleOp{} }
func (m *pbSetThrottleOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetThrottleOp) ProtoMessage()    {}

type pbPromoteOp struct {
	NowNs uint64 `protobuf:"varint,1,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbPromoteOp) Reset()         { *m = pbPromoteOp{} }
func (m *pbPromoteOp) String() string { return oldproto.CompactTextString(m) }
func (*pbPromoteOp) ProtoMessage()    {}

type pbReclaimOp struct {
	NowNs uint64 `protobuf:"varint,1,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbReclaimOp) Reset()         { *m = pbReclaimOp{} }
func (m *pbReclaimOp) String() string { return oldproto.CompactTextString(m) }
func (*pbReclaimOp) ProtoMessage()    {}

type pbBulkActionOp struct {
	JobIDs      []string `protobuf:"bytes,1,rep,name=job_ids,json=jobIds,proto3" json:"job_ids,omitempty"`
	Action      string   `protobuf:"bytes,2,opt,name=action,proto3" json:"action,omitempty"`
	MoveToQueue string   `protobuf:"bytes,3,opt,name=move_to_queue,json=moveToQueue,proto3" json:"move_to_queue,omitempty"`
	Priority    int32    `protobuf:"varint,4,opt,name=priority,proto3" json:"priority,omitempty"`
	NowNs       uint64   `protobuf:"varint,5,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbBulkActionOp) Reset()         { *m = pbBulkActionOp{} }
func (m *pbBulkActionOp) String() string { return oldproto.CompactTextString(m) }
func (*pbBulkActionOp) ProtoMessage()    {}

type pbCleanUniqueOp struct {
	NowNs uint64 `protobuf:"varint,1,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbCleanUniqueOp) Reset()         { *m = pbCleanUniqueOp{} }
func (m *pbCleanUniqueOp) String() string { return oldproto.CompactTextString(m) }
func (*pbCleanUniqueOp) ProtoMessage()    {}

type pbCleanRateOp struct {
	CutoffNs uint64 `protobuf:"varint,1,opt,name=cutoff_ns,json=cutoffNs,proto3" json:"cutoff_ns,omitempty"`
}

func (m *pbCleanRateOp) Reset()         { *m = pbCleanRateOp{} }
func (m *pbCleanRateOp) String() string { return oldproto.CompactTextString(m) }
func (*pbCleanRateOp) ProtoMessage()    {}

type pbSetBudgetOp struct {
	ID          string  `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
	Scope       string  `protobuf:"bytes,2,opt,name=scope,proto3" json:"scope,omitempty"`
	Target      string  `protobuf:"bytes,3,opt,name=target,proto3" json:"target,omitempty"`
	DailyUsd    float64 `protobuf:"fixed64,4,opt,name=daily_usd,json=dailyUsd,proto3" json:"daily_usd,omitempty"`
	HasDailyUsd bool    `protobuf:"varint,5,opt,name=has_daily_usd,json=hasDailyUsd,proto3" json:"has_daily_usd,omitempty"`
	PerJobUsd   float64 `protobuf:"fixed64,6,opt,name=per_job_usd,json=perJobUsd,proto3" json:"per_job_usd,omitempty"`
	HasPerJob   bool    `protobuf:"varint,7,opt,name=has_per_job,json=hasPerJob,proto3" json:"has_per_job,omitempty"`
	OnExceed    string  `protobuf:"bytes,8,opt,name=on_exceed,json=onExceed,proto3" json:"on_exceed,omitempty"`
	CreatedAt   string  `protobuf:"bytes,9,opt,name=created_at,json=createdAt,proto3" json:"created_at,omitempty"`
}

func (m *pbSetBudgetOp) Reset()         { *m = pbSetBudgetOp{} }
func (m *pbSetBudgetOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetBudgetOp) ProtoMessage()    {}

type pbDeleteBudgetOp struct {
	Scope  string `protobuf:"bytes,1,opt,name=scope,proto3" json:"scope,omitempty"`
	Target string `protobuf:"bytes,2,opt,name=target,proto3" json:"target,omitempty"`
}

func (m *pbDeleteBudgetOp) Reset()         { *m = pbDeleteBudgetOp{} }
func (m *pbDeleteBudgetOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteBudgetOp) ProtoMessage()    {}

func encodeRaftOp(opType OpType, data any) ([]byte, error) {
	pb, err := buildPBOp(opType, data)
	if err != nil {
		return nil, err
	}
	wire, err := oldproto.Marshal(pb)
	if err != nil {
		return nil, err
	}
	return append(append([]byte{}, raftProtoPrefix...), wire...), nil
}

func encodePBEnvelope(op *pbOp) ([]byte, error) {
	wire, err := oldproto.Marshal(op)
	if err != nil {
		return nil, err
	}
	return append(append([]byte{}, raftProtoPrefix...), wire...), nil
}

// MarshalMultiInputs encodes a MultiOp directly from typed inputs using
// protobuf wire format (with JSON fallback per unknown op payload).
func MarshalMultiInputs(inputs []OpInput) ([]byte, error) {
	pbm := &pbMultiOp{Ops: make([]*pbOp, 0, len(inputs))}
	for _, in := range inputs {
		sub, err := buildPBOp(in.Type, in.Data)
		if err != nil {
			return nil, err
		}
		pbm.Ops = append(pbm.Ops, sub)
	}
	return encodePBEnvelope(&pbOp{
		Type:  uint32(OpMulti),
		Multi: pbm,
	})
}

func decodeRaftOp(data []byte) (*DecodedRaftOp, error) {
	if !bytes.HasPrefix(data, raftProtoPrefix) {
		return nil, fmt.Errorf("raft op is not protobuf encoded")
	}
	var pb pbOp
	if err := oldproto.Unmarshal(data[len(raftProtoPrefix):], &pb); err != nil {
		return nil, fmt.Errorf("unmarshal protobuf op: %w", err)
	}
	return fromPBOp(&pb)
}

func buildPBOp(opType OpType, data any) (*pbOp, error) {
	op := &pbOp{Type: uint32(opType)}
	switch opType {
	case OpEnqueue:
		v, ok := data.(EnqueueOp)
		if !ok {
			return nil, fmt.Errorf("enqueue op type mismatch: %T", data)
		}
		op.Enqueue = toPBEnqueue(v)
	case OpEnqueueBatch:
		v, ok := data.(EnqueueBatchOp)
		if !ok {
			return nil, fmt.Errorf("enqueue batch op type mismatch: %T", data)
		}
		op.EnqueueBatch = toPBEnqueueBatch(v)
	case OpFetch:
		v, ok := data.(FetchOp)
		if !ok {
			return nil, fmt.Errorf("fetch op type mismatch: %T", data)
		}
		op.Fetch = toPBFetch(v)
	case OpFetchBatch:
		v, ok := data.(FetchBatchOp)
		if !ok {
			return nil, fmt.Errorf("fetch batch op type mismatch: %T", data)
		}
		op.FetchBatch = toPBFetchBatch(v)
	case OpAck:
		v, ok := data.(AckOp)
		if !ok {
			return nil, fmt.Errorf("ack op type mismatch: %T", data)
		}
		op.Ack = toPBAck(v)
	case OpAckBatch:
		v, ok := data.(AckBatchOp)
		if !ok {
			return nil, fmt.Errorf("ack batch op type mismatch: %T", data)
		}
		op.AckBatch = toPBAckBatch(v)
	case OpFail:
		v, ok := data.(FailOp)
		if !ok {
			return nil, fmt.Errorf("fail op type mismatch: %T", data)
		}
		op.Fail = toPBFail(v)
	case OpHeartbeat:
		v, ok := data.(HeartbeatOp)
		if !ok {
			return nil, fmt.Errorf("heartbeat op type mismatch: %T", data)
		}
		op.Heartbeat = toPBHeartbeat(v)
	case OpRetryJob:
		v, ok := data.(RetryJobOp)
		if !ok {
			return nil, fmt.Errorf("retry job op type mismatch: %T", data)
		}
		op.RetryJob = toPBRetryJob(v)
	case OpCancelJob:
		v, ok := data.(CancelJobOp)
		if !ok {
			return nil, fmt.Errorf("cancel job op type mismatch: %T", data)
		}
		op.CancelJob = toPBCancelJob(v)
	case OpMoveJob:
		v, ok := data.(MoveJobOp)
		if !ok {
			return nil, fmt.Errorf("move job op type mismatch: %T", data)
		}
		op.MoveJob = toPBMoveJob(v)
	case OpDeleteJob:
		v, ok := data.(DeleteJobOp)
		if !ok {
			return nil, fmt.Errorf("delete job op type mismatch: %T", data)
		}
		op.DeleteJob = toPBDeleteJob(v)
	case OpPauseQueue:
		v, ok := data.(QueueOp)
		if !ok {
			return nil, fmt.Errorf("pause queue op type mismatch: %T", data)
		}
		op.PauseQueue = toPBQueueOp(v)
	case OpResumeQueue:
		v, ok := data.(QueueOp)
		if !ok {
			return nil, fmt.Errorf("resume queue op type mismatch: %T", data)
		}
		op.ResumeQueue = toPBQueueOp(v)
	case OpClearQueue:
		v, ok := data.(QueueOp)
		if !ok {
			return nil, fmt.Errorf("clear queue op type mismatch: %T", data)
		}
		op.ClearQueue = toPBQueueOp(v)
	case OpDeleteQueue:
		v, ok := data.(QueueOp)
		if !ok {
			return nil, fmt.Errorf("delete queue op type mismatch: %T", data)
		}
		op.DeleteQueue = toPBQueueOp(v)
	case OpSetConcurrency:
		v, ok := data.(SetConcurrencyOp)
		if !ok {
			return nil, fmt.Errorf("set concurrency op type mismatch: %T", data)
		}
		op.SetConc = toPBSetConc(v)
	case OpSetThrottle:
		v, ok := data.(SetThrottleOp)
		if !ok {
			return nil, fmt.Errorf("set throttle op type mismatch: %T", data)
		}
		op.SetThrottle = toPBSetThrottle(v)
	case OpRemoveThrottle:
		v, ok := data.(QueueOp)
		if !ok {
			return nil, fmt.Errorf("remove throttle op type mismatch: %T", data)
		}
		op.RemoveThr = toPBQueueOp(v)
	case OpPromote:
		v, ok := data.(PromoteOp)
		if !ok {
			return nil, fmt.Errorf("promote op type mismatch: %T", data)
		}
		op.Promote = toPBPromote(v)
	case OpReclaim:
		v, ok := data.(ReclaimOp)
		if !ok {
			return nil, fmt.Errorf("reclaim op type mismatch: %T", data)
		}
		op.Reclaim = toPBReclaim(v)
	case OpBulkAction:
		v, ok := data.(BulkActionOp)
		if !ok {
			return nil, fmt.Errorf("bulk action op type mismatch: %T", data)
		}
		op.BulkAction = toPBBulkAction(v)
	case OpCleanUnique:
		v, ok := data.(CleanUniqueOp)
		if !ok {
			return nil, fmt.Errorf("clean unique op type mismatch: %T", data)
		}
		op.CleanUnique = toPBCleanUnique(v)
	case OpCleanRateLimit:
		v, ok := data.(CleanRateLimitOp)
		if !ok {
			return nil, fmt.Errorf("clean rate op type mismatch: %T", data)
		}
		op.CleanRate = toPBCleanRate(v)
	case OpSetBudget:
		v, ok := data.(SetBudgetOp)
		if !ok {
			return nil, fmt.Errorf("set budget op type mismatch: %T", data)
		}
		op.SetBudget = toPBSetBudget(v)
	case OpDeleteBudget:
		v, ok := data.(DeleteBudgetOp)
		if !ok {
			return nil, fmt.Errorf("delete budget op type mismatch: %T", data)
		}
		op.DeleteBudget = toPBDeleteBudget(v)
	case OpSetProvider:
		v, ok := data.(SetProviderOp)
		if !ok {
			return nil, fmt.Errorf("set provider op type mismatch: %T", data)
		}
		op.SetProvider = toPBSetProvider(v)
	case OpDeleteProvider:
		v, ok := data.(DeleteProviderOp)
		if !ok {
			return nil, fmt.Errorf("delete provider op type mismatch: %T", data)
		}
		op.DeleteProvider = toPBDeleteProvider(v)
	case OpSetQueueProvider:
		v, ok := data.(SetQueueProviderOp)
		if !ok {
			return nil, fmt.Errorf("set queue provider op type mismatch: %T", data)
		}
		op.SetQueueProvider = toPBSetQueueProvider(v)
	case OpMulti:
		v, ok := data.(MultiOp)
		if !ok {
			return nil, fmt.Errorf("multi op type mismatch: %T", data)
		}
		pbm := &pbMultiOp{Ops: make([]*pbOp, 0, len(v.Ops))}
		for _, sub := range v.Ops {
			sp, err := buildPBSubOp(sub)
			if err != nil {
				return nil, err
			}
			pbm.Ops = append(pbm.Ops, sp)
		}
		op.Multi = pbm
	default:
		return nil, fmt.Errorf("unsupported raft op type: %d", opType)
	}
	return op, nil
}

func buildPBSubOp(sub Op) (*pbOp, error) {
	op := &pbOp{Type: uint32(sub.Type)}
	switch sub.Type {
	case OpEnqueue:
		var v EnqueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Enqueue = toPBEnqueue(v)
	case OpEnqueueBatch:
		var v EnqueueBatchOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.EnqueueBatch = toPBEnqueueBatch(v)
	case OpFetch:
		var v FetchOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Fetch = toPBFetch(v)
	case OpFetchBatch:
		var v FetchBatchOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.FetchBatch = toPBFetchBatch(v)
	case OpAck:
		var v AckOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Ack = toPBAck(v)
	case OpAckBatch:
		var v AckBatchOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.AckBatch = toPBAckBatch(v)
	case OpFail:
		var v FailOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Fail = toPBFail(v)
	case OpHeartbeat:
		var v HeartbeatOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Heartbeat = toPBHeartbeat(v)
	case OpRetryJob:
		var v RetryJobOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.RetryJob = toPBRetryJob(v)
	case OpCancelJob:
		var v CancelJobOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.CancelJob = toPBCancelJob(v)
	case OpMoveJob:
		var v MoveJobOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.MoveJob = toPBMoveJob(v)
	case OpDeleteJob:
		var v DeleteJobOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteJob = toPBDeleteJob(v)
	case OpPauseQueue:
		var v QueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.PauseQueue = toPBQueueOp(v)
	case OpResumeQueue:
		var v QueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.ResumeQueue = toPBQueueOp(v)
	case OpClearQueue:
		var v QueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.ClearQueue = toPBQueueOp(v)
	case OpDeleteQueue:
		var v QueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteQueue = toPBQueueOp(v)
	case OpSetConcurrency:
		var v SetConcurrencyOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetConc = toPBSetConc(v)
	case OpSetThrottle:
		var v SetThrottleOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetThrottle = toPBSetThrottle(v)
	case OpRemoveThrottle:
		var v QueueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.RemoveThr = toPBQueueOp(v)
	case OpPromote:
		var v PromoteOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Promote = toPBPromote(v)
	case OpReclaim:
		var v ReclaimOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.Reclaim = toPBReclaim(v)
	case OpBulkAction:
		var v BulkActionOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.BulkAction = toPBBulkAction(v)
	case OpCleanUnique:
		var v CleanUniqueOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.CleanUnique = toPBCleanUnique(v)
	case OpCleanRateLimit:
		var v CleanRateLimitOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.CleanRate = toPBCleanRate(v)
	case OpSetBudget:
		var v SetBudgetOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetBudget = toPBSetBudget(v)
	case OpDeleteBudget:
		var v DeleteBudgetOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteBudget = toPBDeleteBudget(v)
	case OpSetProvider:
		var v SetProviderOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetProvider = toPBSetProvider(v)
	case OpDeleteProvider:
		var v DeleteProviderOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteProvider = toPBDeleteProvider(v)
	case OpSetQueueProvider:
		var v SetQueueProviderOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetQueueProvider = toPBSetQueueProvider(v)
	default:
		return nil, fmt.Errorf("unsupported multi sub-op type: %d", sub.Type)
	}
	return op, nil
}

func fromPBOp(op *pbOp) (*DecodedRaftOp, error) {
	out := &DecodedRaftOp{Type: OpType(op.Type)}
	if op.Multi != nil {
		out.Multi = make([]*DecodedRaftOp, 0, len(op.Multi.Ops))
		for _, sub := range op.Multi.Ops {
			decoded, err := fromPBOp(sub)
			if err != nil {
				return nil, err
			}
			out.Multi = append(out.Multi, decoded)
		}
		return out, nil
	}
	if op.Enqueue != nil {
		v := fromPBEnqueue(op.Enqueue)
		out.Enqueue = &v
		return out, nil
	}
	if op.EnqueueBatch != nil {
		v := fromPBEnqueueBatch(op.EnqueueBatch)
		out.EnqueueBatch = &v
		return out, nil
	}
	if op.Fetch != nil {
		v := fromPBFetch(op.Fetch)
		out.Fetch = &v
		return out, nil
	}
	if op.FetchBatch != nil {
		v := fromPBFetchBatch(op.FetchBatch)
		out.FetchBatch = &v
		return out, nil
	}
	if op.Ack != nil {
		v := fromPBAck(op.Ack)
		out.Ack = &v
		return out, nil
	}
	if op.AckBatch != nil {
		v := fromPBAckBatch(op.AckBatch)
		out.AckBatch = &v
		return out, nil
	}
	if op.Fail != nil {
		v := fromPBFail(op.Fail)
		out.Fail = &v
		return out, nil
	}
	if op.Heartbeat != nil {
		v := fromPBHeartbeat(op.Heartbeat)
		out.Heartbeat = &v
		return out, nil
	}
	if op.RetryJob != nil {
		v := fromPBRetryJob(op.RetryJob)
		out.RetryJob = &v
		return out, nil
	}
	if op.CancelJob != nil {
		v := fromPBCancelJob(op.CancelJob)
		out.CancelJob = &v
		return out, nil
	}
	if op.MoveJob != nil {
		v := fromPBMoveJob(op.MoveJob)
		out.MoveJob = &v
		return out, nil
	}
	if op.DeleteJob != nil {
		v := fromPBDeleteJob(op.DeleteJob)
		out.DeleteJob = &v
		return out, nil
	}
	if op.PauseQueue != nil {
		v := fromPBQueueOp(op.PauseQueue)
		out.PauseQueue = &v
		return out, nil
	}
	if op.ResumeQueue != nil {
		v := fromPBQueueOp(op.ResumeQueue)
		out.ResumeQueue = &v
		return out, nil
	}
	if op.ClearQueue != nil {
		v := fromPBQueueOp(op.ClearQueue)
		out.ClearQueue = &v
		return out, nil
	}
	if op.DeleteQueue != nil {
		v := fromPBQueueOp(op.DeleteQueue)
		out.DeleteQueue = &v
		return out, nil
	}
	if op.SetConc != nil {
		v := fromPBSetConc(op.SetConc)
		out.SetConc = &v
		return out, nil
	}
	if op.SetThrottle != nil {
		v := fromPBSetThrottle(op.SetThrottle)
		out.SetThrottle = &v
		return out, nil
	}
	if op.RemoveThr != nil {
		v := fromPBQueueOp(op.RemoveThr)
		out.RemoveThr = &v
		return out, nil
	}
	if op.Promote != nil {
		v := fromPBPromote(op.Promote)
		out.Promote = &v
		return out, nil
	}
	if op.Reclaim != nil {
		v := fromPBReclaim(op.Reclaim)
		out.Reclaim = &v
		return out, nil
	}
	if op.BulkAction != nil {
		v := fromPBBulkAction(op.BulkAction)
		out.BulkAction = &v
		return out, nil
	}
	if op.CleanUnique != nil {
		v := fromPBCleanUnique(op.CleanUnique)
		out.CleanUnique = &v
		return out, nil
	}
	if op.CleanRate != nil {
		v := fromPBCleanRate(op.CleanRate)
		out.CleanRate = &v
		return out, nil
	}
	if op.SetBudget != nil {
		v := fromPBSetBudget(op.SetBudget)
		out.SetBudget = &v
		return out, nil
	}
	if op.DeleteBudget != nil {
		v := fromPBDeleteBudget(op.DeleteBudget)
		out.DeleteBudget = &v
		return out, nil
	}
	if op.SetProvider != nil {
		v := fromPBSetProvider(op.SetProvider)
		out.SetProvider = &v
		return out, nil
	}
	if op.DeleteProvider != nil {
		v := fromPBDeleteProvider(op.DeleteProvider)
		out.DeleteProvider = &v
		return out, nil
	}
	if op.SetQueueProvider != nil {
		v := fromPBSetQueueProvider(op.SetQueueProvider)
		out.SetQueueProvider = &v
		return out, nil
	}
	return nil, fmt.Errorf("protobuf op %d missing payload", op.Type)
}

func toPBEnqueue(op EnqueueOp) *pbEnqueueOp {
	p := &pbEnqueueOp{
		JobID:        op.JobID,
		Queue:        op.Queue,
		State:        op.State,
		Payload:      append([]byte(nil), op.Payload...),
		Priority:     int32(op.Priority),
		MaxRetries:   int32(op.MaxRetries),
		Backoff:      op.Backoff,
		BaseDelayMs:  int32(op.BaseDelayMs),
		MaxDelayMs:   int32(op.MaxDelayMs),
		UniqueKey:    op.UniqueKey,
		UniquePeriod: int32(op.UniquePeriod),
		Tags:         append([]byte(nil), op.Tags...),
		CreatedAtNs:  op.CreatedAt.UnixNano(),
		NowNs:        op.NowNs,
		BatchID:      op.BatchID,
		Checkpoint:   append([]byte(nil), op.Checkpoint...),
		ResultSchema: append([]byte(nil), op.ResultSchema...),
		ParentID:     op.ParentID,
		ChainID:      op.ChainID,
		ChainConfig:  append([]byte(nil), op.ChainConfig...),
	}
	if op.Routing != nil {
		b, _ := json.Marshal(op.Routing)
		p.Routing = b
	}
	if op.ChainStep != nil {
		p.HasChainStep = true
		p.ChainStep = int32(*op.ChainStep)
	}
	if op.ScheduledAt != nil {
		p.HasScheduledAt = true
		p.ScheduledAtNs = op.ScheduledAt.UnixNano()
	}
	if op.ExpireAt != nil {
		p.HasExpireAt = true
		p.ExpireAtNs = op.ExpireAt.UnixNano()
	}
	if op.Agent != nil {
		p.HasAgent = true
		p.AgentMaxIterations = int32(op.Agent.MaxIterations)
		p.AgentMaxCostUsd = op.Agent.MaxCostUSD
		p.AgentIterationTimeout = op.Agent.IterationTimeout
		p.AgentIteration = int32(op.Agent.Iteration)
		p.AgentTotalCostUsd = op.Agent.TotalCostUSD
	}
	return p
}

func fromPBEnqueue(op *pbEnqueueOp) EnqueueOp {
	out := EnqueueOp{
		JobID:        op.JobID,
		Queue:        op.Queue,
		State:        op.State,
		Payload:      append([]byte(nil), op.Payload...),
		Priority:     int(op.Priority),
		MaxRetries:   int(op.MaxRetries),
		Backoff:      op.Backoff,
		BaseDelayMs:  int(op.BaseDelayMs),
		MaxDelayMs:   int(op.MaxDelayMs),
		UniqueKey:    op.UniqueKey,
		UniquePeriod: int(op.UniquePeriod),
		Tags:         append([]byte(nil), op.Tags...),
		CreatedAt:    time.Unix(0, op.CreatedAtNs).UTC(),
		NowNs:        op.NowNs,
		BatchID:      op.BatchID,
		Checkpoint:   append([]byte(nil), op.Checkpoint...),
		ResultSchema: append([]byte(nil), op.ResultSchema...),
		ParentID:     op.ParentID,
		ChainID:      op.ChainID,
		ChainConfig:  append([]byte(nil), op.ChainConfig...),
	}
	if len(op.Routing) > 0 {
		var r RoutingConfig
		if err := json.Unmarshal(op.Routing, &r); err == nil {
			out.Routing = &r
		}
	}
	if op.HasChainStep {
		v := int(op.ChainStep)
		out.ChainStep = &v
	}
	if op.HasScheduledAt {
		t := time.Unix(0, op.ScheduledAtNs).UTC()
		out.ScheduledAt = &t
	}
	if op.HasExpireAt {
		t := time.Unix(0, op.ExpireAtNs).UTC()
		out.ExpireAt = &t
	}
	if op.HasAgent {
		out.Agent = &AgentState{
			MaxIterations:    int(op.AgentMaxIterations),
			MaxCostUSD:       op.AgentMaxCostUsd,
			IterationTimeout: op.AgentIterationTimeout,
			Iteration:        int(op.AgentIteration),
			TotalCostUSD:     op.AgentTotalCostUsd,
		}
	}
	return out
}

func toPBEnqueueBatch(op EnqueueBatchOp) *pbEnqueueBatchOp {
	p := &pbEnqueueBatchOp{
		Jobs:    make([]*pbEnqueueOp, 0, len(op.Jobs)),
		BatchID: op.BatchID,
	}
	for _, j := range op.Jobs {
		p.Jobs = append(p.Jobs, toPBEnqueue(j))
	}
	if op.Batch != nil {
		p.Batch = &pbBatchOp{
			CallbackQueue:   op.Batch.CallbackQueue,
			CallbackPayload: append([]byte(nil), op.Batch.CallbackPayload...),
		}
	}
	return p
}

func fromPBEnqueueBatch(op *pbEnqueueBatchOp) EnqueueBatchOp {
	out := EnqueueBatchOp{
		Jobs:    make([]EnqueueOp, 0, len(op.Jobs)),
		BatchID: op.BatchID,
	}
	for _, j := range op.Jobs {
		out.Jobs = append(out.Jobs, fromPBEnqueue(j))
	}
	if op.Batch != nil {
		out.Batch = &BatchOp{
			CallbackQueue:   op.Batch.CallbackQueue,
			CallbackPayload: append([]byte(nil), op.Batch.CallbackPayload...),
		}
	}
	return out
}

func toPBFetch(op FetchOp) *pbFetchOp {
	return &pbFetchOp{
		Queues:        append([]string(nil), op.Queues...),
		WorkerID:      op.WorkerID,
		Hostname:      op.Hostname,
		LeaseDuration: int32(op.LeaseDuration),
		NowNs:         op.NowNs,
		RandomSeed:    op.RandomSeed,
	}
}

func fromPBFetch(op *pbFetchOp) FetchOp {
	return FetchOp{
		Queues:        append([]string(nil), op.Queues...),
		WorkerID:      op.WorkerID,
		Hostname:      op.Hostname,
		LeaseDuration: int(op.LeaseDuration),
		NowNs:         op.NowNs,
		RandomSeed:    op.RandomSeed,
	}
}

func toPBFetchBatch(op FetchBatchOp) *pbFetchBatchOp {
	return &pbFetchBatchOp{
		Queues:        append([]string(nil), op.Queues...),
		WorkerID:      op.WorkerID,
		Hostname:      op.Hostname,
		LeaseDuration: int32(op.LeaseDuration),
		Count:         int32(op.Count),
		NowNs:         op.NowNs,
		RandomSeed:    op.RandomSeed,
	}
}

func fromPBFetchBatch(op *pbFetchBatchOp) FetchBatchOp {
	return FetchBatchOp{
		Queues:        append([]string(nil), op.Queues...),
		WorkerID:      op.WorkerID,
		Hostname:      op.Hostname,
		LeaseDuration: int(op.LeaseDuration),
		Count:         int(op.Count),
		NowNs:         op.NowNs,
		RandomSeed:    op.RandomSeed,
	}
}

func toPBAck(op AckOp) *pbAckOp {
	return &pbAckOp{
		JobID:       op.JobID,
		Result:      append([]byte(nil), op.Result...),
		Usage:       toPBUsage(op.Usage),
		NowNs:       op.NowNs,
		Checkpoint:  append([]byte(nil), op.Checkpoint...),
		AgentStatus: op.AgentStatus,
		HoldReason:  op.HoldReason,
		Trace:       append([]byte(nil), op.Trace...),
	}
}

func fromPBAck(op *pbAckOp) AckOp {
	return AckOp{
		JobID:       op.JobID,
		Result:      append([]byte(nil), op.Result...),
		Usage:       fromPBUsage(op.Usage),
		NowNs:       op.NowNs,
		Checkpoint:  append([]byte(nil), op.Checkpoint...),
		AgentStatus: op.AgentStatus,
		HoldReason:  op.HoldReason,
		Trace:       append([]byte(nil), op.Trace...),
	}
}

func toPBAckBatch(op AckBatchOp) *pbAckBatchOp {
	out := &pbAckBatchOp{Acks: make([]*pbAckOp, 0, len(op.Acks)), NowNs: op.NowNs}
	for _, a := range op.Acks {
		out.Acks = append(out.Acks, toPBAck(a))
	}
	return out
}

func fromPBAckBatch(op *pbAckBatchOp) AckBatchOp {
	out := AckBatchOp{Acks: make([]AckOp, 0, len(op.Acks)), NowNs: op.NowNs}
	for _, a := range op.Acks {
		out.Acks = append(out.Acks, fromPBAck(a))
	}
	return out
}

func toPBFail(op FailOp) *pbFailOp {
	return &pbFailOp{
		JobID:         op.JobID,
		Error:         op.Error,
		Backtrace:     op.Backtrace,
		NowNs:         op.NowNs,
		ProviderError: op.ProviderError,
	}
}

func fromPBFail(op *pbFailOp) FailOp {
	return FailOp{
		JobID:         op.JobID,
		Error:         op.Error,
		Backtrace:     op.Backtrace,
		NowNs:         op.NowNs,
		ProviderError: op.ProviderError,
	}
}

func toPBHeartbeat(op HeartbeatOp) *pbHeartbeatOp {
	out := &pbHeartbeatOp{Jobs: make([]*pbHeartbeatJob, 0, len(op.Jobs)), NowNs: op.NowNs}
	for id, j := range op.Jobs {
		item := &pbHeartbeatJob{JobID: id}
		if len(j.Progress) > 0 {
			item.Progress = append([]byte(nil), j.Progress...)
			item.HasProgress = true
		}
		if len(j.Checkpoint) > 0 {
			item.Checkpoint = append([]byte(nil), j.Checkpoint...)
			item.HasCP = true
		}
		item.Usage = toPBUsage(j.Usage)
		item.StreamDelta = j.StreamDelta
		out.Jobs = append(out.Jobs, item)
	}
	return out
}

func fromPBHeartbeat(op *pbHeartbeatOp) HeartbeatOp {
	out := HeartbeatOp{Jobs: make(map[string]HeartbeatJobOp, len(op.Jobs)), NowNs: op.NowNs}
	for _, item := range op.Jobs {
		j := HeartbeatJobOp{}
		if item.HasProgress {
			j.Progress = append([]byte(nil), item.Progress...)
		}
		if item.HasCP {
			j.Checkpoint = append([]byte(nil), item.Checkpoint...)
		}
		j.Usage = fromPBUsage(item.Usage)
		j.StreamDelta = item.StreamDelta
		out.Jobs[item.JobID] = j
	}
	return out
}

func toPBUsage(u *UsageReport) *pbUsageReport {
	if u == nil {
		return nil
	}
	return &pbUsageReport{
		InputTokens:         u.InputTokens,
		OutputTokens:        u.OutputTokens,
		CacheCreationTokens: u.CacheCreationTokens,
		CacheReadTokens:     u.CacheReadTokens,
		Model:               u.Model,
		Provider:            u.Provider,
		CostUsd:             u.CostUSD,
	}
}

func fromPBUsage(u *pbUsageReport) *UsageReport {
	if u == nil {
		return nil
	}
	return &UsageReport{
		InputTokens:         u.InputTokens,
		OutputTokens:        u.OutputTokens,
		CacheCreationTokens: u.CacheCreationTokens,
		CacheReadTokens:     u.CacheReadTokens,
		Model:               u.Model,
		Provider:            u.Provider,
		CostUSD:             u.CostUsd,
	}
}

func toPBRetryJob(op RetryJobOp) *pbRetryJobOp {
	return &pbRetryJobOp{JobID: op.JobID, NowNs: op.NowNs}
}

func fromPBRetryJob(op *pbRetryJobOp) RetryJobOp {
	return RetryJobOp{JobID: op.JobID, NowNs: op.NowNs}
}

func toPBCancelJob(op CancelJobOp) *pbCancelJobOp {
	return &pbCancelJobOp{JobID: op.JobID, NowNs: op.NowNs}
}

func fromPBCancelJob(op *pbCancelJobOp) CancelJobOp {
	return CancelJobOp{JobID: op.JobID, NowNs: op.NowNs}
}

func toPBMoveJob(op MoveJobOp) *pbMoveJobOp {
	return &pbMoveJobOp{JobID: op.JobID, TargetQueue: op.TargetQueue, NowNs: op.NowNs}
}

func fromPBMoveJob(op *pbMoveJobOp) MoveJobOp {
	return MoveJobOp{JobID: op.JobID, TargetQueue: op.TargetQueue, NowNs: op.NowNs}
}

func toPBDeleteJob(op DeleteJobOp) *pbDeleteJobOp {
	return &pbDeleteJobOp{JobID: op.JobID}
}

func fromPBDeleteJob(op *pbDeleteJobOp) DeleteJobOp {
	return DeleteJobOp{JobID: op.JobID}
}

func toPBQueueOp(op QueueOp) *pbQueueOp {
	return &pbQueueOp{Queue: op.Queue}
}

func fromPBQueueOp(op *pbQueueOp) QueueOp {
	return QueueOp{Queue: op.Queue}
}

func toPBSetConc(op SetConcurrencyOp) *pbSetConcOp {
	return &pbSetConcOp{Queue: op.Queue, Max: int32(op.Max)}
}

func fromPBSetConc(op *pbSetConcOp) SetConcurrencyOp {
	return SetConcurrencyOp{Queue: op.Queue, Max: int(op.Max)}
}

func toPBSetThrottle(op SetThrottleOp) *pbSetThrottleOp {
	return &pbSetThrottleOp{Queue: op.Queue, Rate: int32(op.Rate), WindowMs: int32(op.WindowMs)}
}

func fromPBSetThrottle(op *pbSetThrottleOp) SetThrottleOp {
	return SetThrottleOp{Queue: op.Queue, Rate: int(op.Rate), WindowMs: int(op.WindowMs)}
}

func toPBPromote(op PromoteOp) *pbPromoteOp {
	return &pbPromoteOp{NowNs: op.NowNs}
}

func fromPBPromote(op *pbPromoteOp) PromoteOp {
	return PromoteOp{NowNs: op.NowNs}
}

func toPBReclaim(op ReclaimOp) *pbReclaimOp {
	return &pbReclaimOp{NowNs: op.NowNs}
}

func fromPBReclaim(op *pbReclaimOp) ReclaimOp {
	return ReclaimOp{NowNs: op.NowNs}
}

func toPBBulkAction(op BulkActionOp) *pbBulkActionOp {
	return &pbBulkActionOp{
		JobIDs:      append([]string(nil), op.JobIDs...),
		Action:      op.Action,
		MoveToQueue: op.MoveToQueue,
		Priority:    int32(op.Priority),
		NowNs:       op.NowNs,
	}
}

func fromPBBulkAction(op *pbBulkActionOp) BulkActionOp {
	return BulkActionOp{
		JobIDs:      append([]string(nil), op.JobIDs...),
		Action:      op.Action,
		MoveToQueue: op.MoveToQueue,
		Priority:    int(op.Priority),
		NowNs:       op.NowNs,
	}
}

func toPBCleanUnique(op CleanUniqueOp) *pbCleanUniqueOp {
	return &pbCleanUniqueOp{NowNs: op.NowNs}
}

func fromPBCleanUnique(op *pbCleanUniqueOp) CleanUniqueOp {
	return CleanUniqueOp{NowNs: op.NowNs}
}

func toPBCleanRate(op CleanRateLimitOp) *pbCleanRateOp {
	return &pbCleanRateOp{CutoffNs: op.CutoffNs}
}

func fromPBCleanRate(op *pbCleanRateOp) CleanRateLimitOp {
	return CleanRateLimitOp{CutoffNs: op.CutoffNs}
}

type pbSetProviderOp struct {
	Name           string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
	RPMLimit       int32  `protobuf:"varint,2,opt,name=rpm_limit,json=rpmLimit,proto3" json:"rpm_limit,omitempty"`
	HasRPMLimit    bool   `protobuf:"varint,3,opt,name=has_rpm_limit,json=hasRpmLimit,proto3" json:"has_rpm_limit,omitempty"`
	InputTPMLimit  int32  `protobuf:"varint,4,opt,name=input_tpm_limit,json=inputTpmLimit,proto3" json:"input_tpm_limit,omitempty"`
	HasInputTPM    bool   `protobuf:"varint,5,opt,name=has_input_tpm,json=hasInputTpm,proto3" json:"has_input_tpm,omitempty"`
	OutputTPMLimit int32  `protobuf:"varint,6,opt,name=output_tpm_limit,json=outputTpmLimit,proto3" json:"output_tpm_limit,omitempty"`
	HasOutputTPM   bool   `protobuf:"varint,7,opt,name=has_output_tpm,json=hasOutputTpm,proto3" json:"has_output_tpm,omitempty"`
	CreatedAt      string `protobuf:"bytes,8,opt,name=created_at,json=createdAt,proto3" json:"created_at,omitempty"`
}

func (m *pbSetProviderOp) Reset()         { *m = pbSetProviderOp{} }
func (m *pbSetProviderOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetProviderOp) ProtoMessage()    {}

type pbDeleteProviderOp struct {
	Name string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
}

func (m *pbDeleteProviderOp) Reset()         { *m = pbDeleteProviderOp{} }
func (m *pbDeleteProviderOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteProviderOp) ProtoMessage()    {}

type pbSetQueueProviderOp struct {
	Queue    string `protobuf:"bytes,1,opt,name=queue,proto3" json:"queue,omitempty"`
	Provider string `protobuf:"bytes,2,opt,name=provider,proto3" json:"provider,omitempty"`
}

func (m *pbSetQueueProviderOp) Reset()         { *m = pbSetQueueProviderOp{} }
func (m *pbSetQueueProviderOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetQueueProviderOp) ProtoMessage()    {}

func toPBSetBudget(op SetBudgetOp) *pbSetBudgetOp {
	out := &pbSetBudgetOp{
		ID:        op.ID,
		Scope:     op.Scope,
		Target:    op.Target,
		OnExceed:  op.OnExceed,
		CreatedAt: op.CreatedAt,
	}
	if op.DailyUSD != nil {
		out.HasDailyUsd = true
		out.DailyUsd = *op.DailyUSD
	}
	if op.PerJobUSD != nil {
		out.HasPerJob = true
		out.PerJobUsd = *op.PerJobUSD
	}
	return out
}

func fromPBSetBudget(op *pbSetBudgetOp) SetBudgetOp {
	out := SetBudgetOp{
		ID:        op.ID,
		Scope:     op.Scope,
		Target:    op.Target,
		OnExceed:  op.OnExceed,
		CreatedAt: op.CreatedAt,
	}
	if op.HasDailyUsd {
		v := op.DailyUsd
		out.DailyUSD = &v
	}
	if op.HasPerJob {
		v := op.PerJobUsd
		out.PerJobUSD = &v
	}
	return out
}

func toPBDeleteBudget(op DeleteBudgetOp) *pbDeleteBudgetOp {
	return &pbDeleteBudgetOp{
		Scope:  op.Scope,
		Target: op.Target,
	}
}

func fromPBDeleteBudget(op *pbDeleteBudgetOp) DeleteBudgetOp {
	return DeleteBudgetOp{
		Scope:  op.Scope,
		Target: op.Target,
	}
}

func toPBSetProvider(op SetProviderOp) *pbSetProviderOp {
	out := &pbSetProviderOp{
		Name:      op.Name,
		CreatedAt: op.CreatedAt,
	}
	if op.RPMLimit != nil {
		out.HasRPMLimit = true
		out.RPMLimit = int32(*op.RPMLimit)
	}
	if op.InputTPMLimit != nil {
		out.HasInputTPM = true
		out.InputTPMLimit = int32(*op.InputTPMLimit)
	}
	if op.OutputTPMLimit != nil {
		out.HasOutputTPM = true
		out.OutputTPMLimit = int32(*op.OutputTPMLimit)
	}
	return out
}

func fromPBSetProvider(op *pbSetProviderOp) SetProviderOp {
	out := SetProviderOp{
		Name:      op.Name,
		CreatedAt: op.CreatedAt,
	}
	if op.HasRPMLimit {
		v := int(op.RPMLimit)
		out.RPMLimit = &v
	}
	if op.HasInputTPM {
		v := int(op.InputTPMLimit)
		out.InputTPMLimit = &v
	}
	if op.HasOutputTPM {
		v := int(op.OutputTPMLimit)
		out.OutputTPMLimit = &v
	}
	return out
}

func toPBDeleteProvider(op DeleteProviderOp) *pbDeleteProviderOp {
	return &pbDeleteProviderOp{Name: op.Name}
}

func fromPBDeleteProvider(op *pbDeleteProviderOp) DeleteProviderOp {
	return DeleteProviderOp{Name: op.Name}
}

func toPBSetQueueProvider(op SetQueueProviderOp) *pbSetQueueProviderOp {
	return &pbSetQueueProviderOp{Queue: op.Queue, Provider: op.Provider}
}

func fromPBSetQueueProvider(op *pbSetQueueProviderOp) SetQueueProviderOp {
	return SetQueueProviderOp{Queue: op.Queue, Provider: op.Provider}
}
