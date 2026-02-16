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
	CreateNamespace     *CreateNamespaceOp
	DeleteNamespace     *DeleteNamespaceOp
	SetAuthRole         *SetAuthRoleOp
	DeleteAuthRole      *DeleteAuthRoleOp
	AssignAPIKeyRole    *AssignAPIKeyRoleOp
	UnassignAPIKeyRole  *UnassignAPIKeyRoleOp
	SetSSOSettings      *SetSSOSettingsOp
	UpsertAPIKey        *UpsertAPIKeyOp
	DeleteAPIKey        *DeleteAPIKeyOp
	InsertAuditLog      *InsertAuditLogOp
	UpdateAPIKeyUsed    *UpdateAPIKeyUsedOp
	UpsertWebhook       *UpsertWebhookOp
	DeleteWebhook       *DeleteWebhookOp
	UpdateWebhookStatus    *UpdateWebhookStatusOp
	SetNamespaceRateLimit  *SetNamespaceRateLimitOp
	ExpireJobs             *ExpireJobsOp
	PurgeJobs              *PurgeJobsOp
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
	SetQueueProvider    *pbSetQueueProviderOp    `protobuf:"bytes,31,opt,name=set_queue_provider,json=setQueueProvider,proto3" json:"set_queue_provider,omitempty"`
	CreateNamespace     *pbCreateNamespaceOp     `protobuf:"bytes,32,opt,name=create_namespace,json=createNamespace,proto3" json:"create_namespace,omitempty"`
	DeleteNamespace     *pbDeleteNamespaceOp     `protobuf:"bytes,33,opt,name=delete_namespace,json=deleteNamespace,proto3" json:"delete_namespace,omitempty"`
	SetAuthRole         *pbSetAuthRoleOp         `protobuf:"bytes,34,opt,name=set_auth_role,json=setAuthRole,proto3" json:"set_auth_role,omitempty"`
	DeleteAuthRole      *pbDeleteAuthRoleOp      `protobuf:"bytes,35,opt,name=delete_auth_role,json=deleteAuthRole,proto3" json:"delete_auth_role,omitempty"`
	AssignAPIKeyRole    *pbAssignAPIKeyRoleOp    `protobuf:"bytes,36,opt,name=assign_api_key_role,json=assignApiKeyRole,proto3" json:"assign_api_key_role,omitempty"`
	UnassignAPIKeyRole  *pbUnassignAPIKeyRoleOp  `protobuf:"bytes,37,opt,name=unassign_api_key_role,json=unassignApiKeyRole,proto3" json:"unassign_api_key_role,omitempty"`
	SetSSOSettings      *pbSetSSOSettingsOp      `protobuf:"bytes,38,opt,name=set_sso_settings,json=setSsoSettings,proto3" json:"set_sso_settings,omitempty"`
	UpsertAPIKey        *pbUpsertAPIKeyOp        `protobuf:"bytes,39,opt,name=upsert_api_key,json=upsertApiKey,proto3" json:"upsert_api_key,omitempty"`
	DeleteAPIKey        *pbDeleteAPIKeyOp        `protobuf:"bytes,40,opt,name=delete_api_key,json=deleteApiKey,proto3" json:"delete_api_key,omitempty"`
	InsertAuditLog      *pbInsertAuditLogOp      `protobuf:"bytes,41,opt,name=insert_audit_log,json=insertAuditLog,proto3" json:"insert_audit_log,omitempty"`
	UpdateAPIKeyUsed    *pbUpdateAPIKeyUsedOp    `protobuf:"bytes,42,opt,name=update_api_key_used,json=updateApiKeyUsed,proto3" json:"update_api_key_used,omitempty"`
	UpsertWebhook       *pbUpsertWebhookOp       `protobuf:"bytes,43,opt,name=upsert_webhook,json=upsertWebhook,proto3" json:"upsert_webhook,omitempty"`
	DeleteWebhook       *pbDeleteWebhookOp       `protobuf:"bytes,44,opt,name=delete_webhook,json=deleteWebhook,proto3" json:"delete_webhook,omitempty"`
	UpdateWebhookStatus    *pbUpdateWebhookStatusOp    `protobuf:"bytes,45,opt,name=update_webhook_status,json=updateWebhookStatus,proto3" json:"update_webhook_status,omitempty"`
	SetNamespaceRateLimit  *pbSetNamespaceRateLimitOp  `protobuf:"bytes,46,opt,name=set_namespace_rate_limit,json=setNamespaceRateLimit,proto3" json:"set_namespace_rate_limit,omitempty"`
	ExpireJobs             *pbExpireJobsOp             `protobuf:"bytes,47,opt,name=expire_jobs,json=expireJobs,proto3" json:"expire_jobs,omitempty"`
	PurgeJobs              *pbPurgeJobsOp              `protobuf:"bytes,48,opt,name=purge_jobs,json=purgeJobs,proto3" json:"purge_jobs,omitempty"`
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
	StepStatus  string         `protobuf:"bytes,9,opt,name=step_status,json=stepStatus,proto3" json:"step_status,omitempty"`
	ExitReason  string         `protobuf:"bytes,10,opt,name=exit_reason,json=exitReason,proto3" json:"exit_reason,omitempty"`
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

type pbExpireJobsOp struct {
	NowNs uint64 `protobuf:"varint,1,opt,name=now_ns,json=nowNs,proto3" json:"now_ns,omitempty"`
}

func (m *pbExpireJobsOp) Reset()         { *m = pbExpireJobsOp{} }
func (m *pbExpireJobsOp) String() string { return oldproto.CompactTextString(m) }
func (*pbExpireJobsOp) ProtoMessage()    {}

type pbPurgeJobsOp struct {
	CutoffNs uint64 `protobuf:"varint,1,opt,name=cutoff_ns,json=cutoffNs,proto3" json:"cutoff_ns,omitempty"`
}

func (m *pbPurgeJobsOp) Reset()         { *m = pbPurgeJobsOp{} }
func (m *pbPurgeJobsOp) String() string { return oldproto.CompactTextString(m) }
func (*pbPurgeJobsOp) ProtoMessage()    {}

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
	case OpCreateNamespace:
		v, ok := data.(CreateNamespaceOp)
		if !ok {
			return nil, fmt.Errorf("create namespace op type mismatch: %T", data)
		}
		op.CreateNamespace = toPBCreateNamespace(v)
	case OpDeleteNamespace:
		v, ok := data.(DeleteNamespaceOp)
		if !ok {
			return nil, fmt.Errorf("delete namespace op type mismatch: %T", data)
		}
		op.DeleteNamespace = toPBDeleteNamespace(v)
	case OpSetAuthRole:
		v, ok := data.(SetAuthRoleOp)
		if !ok {
			return nil, fmt.Errorf("set auth role op type mismatch: %T", data)
		}
		op.SetAuthRole = toPBSetAuthRole(v)
	case OpDeleteAuthRole:
		v, ok := data.(DeleteAuthRoleOp)
		if !ok {
			return nil, fmt.Errorf("delete auth role op type mismatch: %T", data)
		}
		op.DeleteAuthRole = toPBDeleteAuthRole(v)
	case OpAssignAPIKeyRole:
		v, ok := data.(AssignAPIKeyRoleOp)
		if !ok {
			return nil, fmt.Errorf("assign api key role op type mismatch: %T", data)
		}
		op.AssignAPIKeyRole = toPBAssignAPIKeyRole(v)
	case OpUnassignAPIKeyRole:
		v, ok := data.(UnassignAPIKeyRoleOp)
		if !ok {
			return nil, fmt.Errorf("unassign api key role op type mismatch: %T", data)
		}
		op.UnassignAPIKeyRole = toPBUnassignAPIKeyRole(v)
	case OpSetSSOSettings:
		v, ok := data.(SetSSOSettingsOp)
		if !ok {
			return nil, fmt.Errorf("set sso settings op type mismatch: %T", data)
		}
		op.SetSSOSettings = toPBSetSSOSettings(v)
	case OpUpsertAPIKey:
		v, ok := data.(UpsertAPIKeyOp)
		if !ok {
			return nil, fmt.Errorf("upsert api key op type mismatch: %T", data)
		}
		op.UpsertAPIKey = toPBUpsertAPIKey(v)
	case OpDeleteAPIKey:
		v, ok := data.(DeleteAPIKeyOp)
		if !ok {
			return nil, fmt.Errorf("delete api key op type mismatch: %T", data)
		}
		op.DeleteAPIKey = toPBDeleteAPIKey(v)
	case OpInsertAuditLog:
		v, ok := data.(InsertAuditLogOp)
		if !ok {
			return nil, fmt.Errorf("insert audit log op type mismatch: %T", data)
		}
		op.InsertAuditLog = toPBInsertAuditLog(v)
	case OpUpdateAPIKeyUsed:
		v, ok := data.(UpdateAPIKeyUsedOp)
		if !ok {
			return nil, fmt.Errorf("update api key used op type mismatch: %T", data)
		}
		op.UpdateAPIKeyUsed = toPBUpdateAPIKeyUsed(v)
	case OpUpsertWebhook:
		v, ok := data.(UpsertWebhookOp)
		if !ok {
			return nil, fmt.Errorf("upsert webhook op type mismatch: %T", data)
		}
		op.UpsertWebhook = toPBUpsertWebhook(v)
	case OpDeleteWebhook:
		v, ok := data.(DeleteWebhookOp)
		if !ok {
			return nil, fmt.Errorf("delete webhook op type mismatch: %T", data)
		}
		op.DeleteWebhook = toPBDeleteWebhook(v)
	case OpUpdateWebhookStatus:
		v, ok := data.(UpdateWebhookStatusOp)
		if !ok {
			return nil, fmt.Errorf("update webhook status op type mismatch: %T", data)
		}
		op.UpdateWebhookStatus = toPBUpdateWebhookStatus(v)
	case OpSetNamespaceRateLimit:
		v, ok := data.(SetNamespaceRateLimitOp)
		if !ok {
			return nil, fmt.Errorf("set namespace rate limit op type mismatch: %T", data)
		}
		op.SetNamespaceRateLimit = toPBSetNamespaceRateLimit(v)
	case OpExpireJobs:
		v, ok := data.(ExpireJobsOp)
		if !ok {
			return nil, fmt.Errorf("expire jobs op type mismatch: %T", data)
		}
		op.ExpireJobs = toPBExpireJobs(v)
	case OpPurgeJobs:
		v, ok := data.(PurgeJobsOp)
		if !ok {
			return nil, fmt.Errorf("purge jobs op type mismatch: %T", data)
		}
		op.PurgeJobs = toPBPurgeJobs(v)
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
	case OpCreateNamespace:
		var v CreateNamespaceOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.CreateNamespace = toPBCreateNamespace(v)
	case OpDeleteNamespace:
		var v DeleteNamespaceOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteNamespace = toPBDeleteNamespace(v)
	case OpSetAuthRole:
		var v SetAuthRoleOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetAuthRole = toPBSetAuthRole(v)
	case OpDeleteAuthRole:
		var v DeleteAuthRoleOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteAuthRole = toPBDeleteAuthRole(v)
	case OpAssignAPIKeyRole:
		var v AssignAPIKeyRoleOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.AssignAPIKeyRole = toPBAssignAPIKeyRole(v)
	case OpUnassignAPIKeyRole:
		var v UnassignAPIKeyRoleOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.UnassignAPIKeyRole = toPBUnassignAPIKeyRole(v)
	case OpSetSSOSettings:
		var v SetSSOSettingsOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetSSOSettings = toPBSetSSOSettings(v)
	case OpUpsertAPIKey:
		var v UpsertAPIKeyOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.UpsertAPIKey = toPBUpsertAPIKey(v)
	case OpDeleteAPIKey:
		var v DeleteAPIKeyOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteAPIKey = toPBDeleteAPIKey(v)
	case OpInsertAuditLog:
		var v InsertAuditLogOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.InsertAuditLog = toPBInsertAuditLog(v)
	case OpUpdateAPIKeyUsed:
		var v UpdateAPIKeyUsedOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.UpdateAPIKeyUsed = toPBUpdateAPIKeyUsed(v)
	case OpUpsertWebhook:
		var v UpsertWebhookOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.UpsertWebhook = toPBUpsertWebhook(v)
	case OpDeleteWebhook:
		var v DeleteWebhookOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.DeleteWebhook = toPBDeleteWebhook(v)
	case OpUpdateWebhookStatus:
		var v UpdateWebhookStatusOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.UpdateWebhookStatus = toPBUpdateWebhookStatus(v)
	case OpSetNamespaceRateLimit:
		var v SetNamespaceRateLimitOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.SetNamespaceRateLimit = toPBSetNamespaceRateLimit(v)
	case OpExpireJobs:
		var v ExpireJobsOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.ExpireJobs = toPBExpireJobs(v)
	case OpPurgeJobs:
		var v PurgeJobsOp
		if err := json.Unmarshal(sub.Data, &v); err != nil {
			return nil, err
		}
		op.PurgeJobs = toPBPurgeJobs(v)
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
	if op.CreateNamespace != nil {
		v := fromPBCreateNamespace(op.CreateNamespace)
		out.CreateNamespace = &v
		return out, nil
	}
	if op.DeleteNamespace != nil {
		v := fromPBDeleteNamespace(op.DeleteNamespace)
		out.DeleteNamespace = &v
		return out, nil
	}
	if op.SetAuthRole != nil {
		v := fromPBSetAuthRole(op.SetAuthRole)
		out.SetAuthRole = &v
		return out, nil
	}
	if op.DeleteAuthRole != nil {
		v := fromPBDeleteAuthRole(op.DeleteAuthRole)
		out.DeleteAuthRole = &v
		return out, nil
	}
	if op.AssignAPIKeyRole != nil {
		v := fromPBAssignAPIKeyRole(op.AssignAPIKeyRole)
		out.AssignAPIKeyRole = &v
		return out, nil
	}
	if op.UnassignAPIKeyRole != nil {
		v := fromPBUnassignAPIKeyRole(op.UnassignAPIKeyRole)
		out.UnassignAPIKeyRole = &v
		return out, nil
	}
	if op.SetSSOSettings != nil {
		v := fromPBSetSSOSettings(op.SetSSOSettings)
		out.SetSSOSettings = &v
		return out, nil
	}
	if op.UpsertAPIKey != nil {
		v := fromPBUpsertAPIKey(op.UpsertAPIKey)
		out.UpsertAPIKey = &v
		return out, nil
	}
	if op.DeleteAPIKey != nil {
		v := fromPBDeleteAPIKey(op.DeleteAPIKey)
		out.DeleteAPIKey = &v
		return out, nil
	}
	if op.InsertAuditLog != nil {
		v := fromPBInsertAuditLog(op.InsertAuditLog)
		out.InsertAuditLog = &v
		return out, nil
	}
	if op.UpdateAPIKeyUsed != nil {
		v := fromPBUpdateAPIKeyUsed(op.UpdateAPIKeyUsed)
		out.UpdateAPIKeyUsed = &v
		return out, nil
	}
	if op.UpsertWebhook != nil {
		v := fromPBUpsertWebhook(op.UpsertWebhook)
		out.UpsertWebhook = &v
		return out, nil
	}
	if op.DeleteWebhook != nil {
		v := fromPBDeleteWebhook(op.DeleteWebhook)
		out.DeleteWebhook = &v
		return out, nil
	}
	if op.UpdateWebhookStatus != nil {
		v := fromPBUpdateWebhookStatus(op.UpdateWebhookStatus)
		out.UpdateWebhookStatus = &v
		return out, nil
	}
	if op.SetNamespaceRateLimit != nil {
		v := fromPBSetNamespaceRateLimit(op.SetNamespaceRateLimit)
		out.SetNamespaceRateLimit = &v
		return out, nil
	}
	if op.ExpireJobs != nil {
		v := fromPBExpireJobs(op.ExpireJobs)
		out.ExpireJobs = &v
		return out, nil
	}
	if op.PurgeJobs != nil {
		v := fromPBPurgeJobs(op.PurgeJobs)
		out.PurgeJobs = &v
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
		ParentID:     op.ParentID,
		ChainID:      op.ChainID,
		ChainConfig:  append([]byte(nil), op.ChainConfig...),
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
		ParentID:     op.ParentID,
		ChainID:      op.ChainID,
		ChainConfig:  append([]byte(nil), op.ChainConfig...),
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
		StepStatus:  op.StepStatus,
		ExitReason:  op.ExitReason,
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
		StepStatus:  op.StepStatus,
		ExitReason:  op.ExitReason,
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

func toPBExpireJobs(op ExpireJobsOp) *pbExpireJobsOp {
	return &pbExpireJobsOp{NowNs: op.NowNs}
}

func fromPBExpireJobs(op *pbExpireJobsOp) ExpireJobsOp {
	return ExpireJobsOp{NowNs: op.NowNs}
}

func toPBPurgeJobs(op PurgeJobsOp) *pbPurgeJobsOp {
	return &pbPurgeJobsOp{CutoffNs: op.CutoffNs}
}

func fromPBPurgeJobs(op *pbPurgeJobsOp) PurgeJobsOp {
	return PurgeJobsOp{CutoffNs: op.CutoffNs}
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

// Enterprise pb struct types.

type pbCreateNamespaceOp struct {
	Name string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
}

func (m *pbCreateNamespaceOp) Reset()         { *m = pbCreateNamespaceOp{} }
func (m *pbCreateNamespaceOp) String() string { return oldproto.CompactTextString(m) }
func (*pbCreateNamespaceOp) ProtoMessage()    {}

type pbDeleteNamespaceOp struct {
	Name string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
}

func (m *pbDeleteNamespaceOp) Reset()         { *m = pbDeleteNamespaceOp{} }
func (m *pbDeleteNamespaceOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteNamespaceOp) ProtoMessage()    {}

type pbSetAuthRoleOp struct {
	Name        string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
	Permissions string `protobuf:"bytes,2,opt,name=permissions,proto3" json:"permissions,omitempty"`
	Now         string `protobuf:"bytes,3,opt,name=now,proto3" json:"now,omitempty"`
}

func (m *pbSetAuthRoleOp) Reset()         { *m = pbSetAuthRoleOp{} }
func (m *pbSetAuthRoleOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetAuthRoleOp) ProtoMessage()    {}

type pbDeleteAuthRoleOp struct {
	Name string `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
}

func (m *pbDeleteAuthRoleOp) Reset()         { *m = pbDeleteAuthRoleOp{} }
func (m *pbDeleteAuthRoleOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteAuthRoleOp) ProtoMessage()    {}

type pbAssignAPIKeyRoleOp struct {
	KeyHash string `protobuf:"bytes,1,opt,name=key_hash,json=keyHash,proto3" json:"key_hash,omitempty"`
	Role    string `protobuf:"bytes,2,opt,name=role,proto3" json:"role,omitempty"`
	Now     string `protobuf:"bytes,3,opt,name=now,proto3" json:"now,omitempty"`
}

func (m *pbAssignAPIKeyRoleOp) Reset()         { *m = pbAssignAPIKeyRoleOp{} }
func (m *pbAssignAPIKeyRoleOp) String() string { return oldproto.CompactTextString(m) }
func (*pbAssignAPIKeyRoleOp) ProtoMessage()    {}

type pbUnassignAPIKeyRoleOp struct {
	KeyHash string `protobuf:"bytes,1,opt,name=key_hash,json=keyHash,proto3" json:"key_hash,omitempty"`
	Role    string `protobuf:"bytes,2,opt,name=role,proto3" json:"role,omitempty"`
}

func (m *pbUnassignAPIKeyRoleOp) Reset()         { *m = pbUnassignAPIKeyRoleOp{} }
func (m *pbUnassignAPIKeyRoleOp) String() string { return oldproto.CompactTextString(m) }
func (*pbUnassignAPIKeyRoleOp) ProtoMessage()    {}

type pbSetSSOSettingsOp struct {
	Provider      string `protobuf:"bytes,1,opt,name=provider,proto3" json:"provider,omitempty"`
	OIDCIssuerURL string `protobuf:"bytes,2,opt,name=oidc_issuer_url,json=oidcIssuerUrl,proto3" json:"oidc_issuer_url,omitempty"`
	OIDCClientID  string `protobuf:"bytes,3,opt,name=oidc_client_id,json=oidcClientId,proto3" json:"oidc_client_id,omitempty"`
	SAMLEnabled   int32  `protobuf:"varint,4,opt,name=saml_enabled,json=samlEnabled,proto3" json:"saml_enabled,omitempty"`
	Now           string `protobuf:"bytes,5,opt,name=now,proto3" json:"now,omitempty"`
}

func (m *pbSetSSOSettingsOp) Reset()         { *m = pbSetSSOSettingsOp{} }
func (m *pbSetSSOSettingsOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetSSOSettingsOp) ProtoMessage()    {}

type pbUpsertAPIKeyOp struct {
	KeyHash    string `protobuf:"bytes,1,opt,name=key_hash,json=keyHash,proto3" json:"key_hash,omitempty"`
	Name       string `protobuf:"bytes,2,opt,name=name,proto3" json:"name,omitempty"`
	Namespace  string `protobuf:"bytes,3,opt,name=namespace,proto3" json:"namespace,omitempty"`
	Role       string `protobuf:"bytes,4,opt,name=role,proto3" json:"role,omitempty"`
	QueueScope string `protobuf:"bytes,5,opt,name=queue_scope,json=queueScope,proto3" json:"queue_scope,omitempty"`
	Enabled    int32  `protobuf:"varint,6,opt,name=enabled,proto3" json:"enabled,omitempty"`
	CreatedAt  string `protobuf:"bytes,7,opt,name=created_at,json=createdAt,proto3" json:"created_at,omitempty"`
	ExpiresAt  string `protobuf:"bytes,8,opt,name=expires_at,json=expiresAt,proto3" json:"expires_at,omitempty"`
}

func (m *pbUpsertAPIKeyOp) Reset()         { *m = pbUpsertAPIKeyOp{} }
func (m *pbUpsertAPIKeyOp) String() string { return oldproto.CompactTextString(m) }
func (*pbUpsertAPIKeyOp) ProtoMessage()    {}

type pbDeleteAPIKeyOp struct {
	KeyHash string `protobuf:"bytes,1,opt,name=key_hash,json=keyHash,proto3" json:"key_hash,omitempty"`
}

func (m *pbDeleteAPIKeyOp) Reset()         { *m = pbDeleteAPIKeyOp{} }
func (m *pbDeleteAPIKeyOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteAPIKeyOp) ProtoMessage()    {}

type pbInsertAuditLogOp struct {
	Namespace  string `protobuf:"bytes,1,opt,name=namespace,proto3" json:"namespace,omitempty"`
	Principal  string `protobuf:"bytes,2,opt,name=principal,proto3" json:"principal,omitempty"`
	Role       string `protobuf:"bytes,3,opt,name=role,proto3" json:"role,omitempty"`
	Method     string `protobuf:"bytes,4,opt,name=method,proto3" json:"method,omitempty"`
	Path       string `protobuf:"bytes,5,opt,name=path,proto3" json:"path,omitempty"`
	StatusCode int32  `protobuf:"varint,6,opt,name=status_code,json=statusCode,proto3" json:"status_code,omitempty"`
	Metadata   string `protobuf:"bytes,7,opt,name=metadata,proto3" json:"metadata,omitempty"`
	CreatedAt  string `protobuf:"bytes,8,opt,name=created_at,json=createdAt,proto3" json:"created_at,omitempty"`
}

func (m *pbInsertAuditLogOp) Reset()         { *m = pbInsertAuditLogOp{} }
func (m *pbInsertAuditLogOp) String() string { return oldproto.CompactTextString(m) }
func (*pbInsertAuditLogOp) ProtoMessage()    {}

type pbUpdateAPIKeyUsedOp struct {
	KeyHash string `protobuf:"bytes,1,opt,name=key_hash,json=keyHash,proto3" json:"key_hash,omitempty"`
	Now     string `protobuf:"bytes,2,opt,name=now,proto3" json:"now,omitempty"`
}

func (m *pbUpdateAPIKeyUsedOp) Reset()         { *m = pbUpdateAPIKeyUsedOp{} }
func (m *pbUpdateAPIKeyUsedOp) String() string { return oldproto.CompactTextString(m) }
func (*pbUpdateAPIKeyUsedOp) ProtoMessage()    {}

type pbUpsertWebhookOp struct {
	ID         string `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
	URL        string `protobuf:"bytes,2,opt,name=url,proto3" json:"url,omitempty"`
	Events     string `protobuf:"bytes,3,opt,name=events,proto3" json:"events,omitempty"`
	Secret     string `protobuf:"bytes,4,opt,name=secret,proto3" json:"secret,omitempty"`
	Enabled    int32  `protobuf:"varint,5,opt,name=enabled,proto3" json:"enabled,omitempty"`
	RetryLimit int32  `protobuf:"varint,6,opt,name=retry_limit,json=retryLimit,proto3" json:"retry_limit,omitempty"`
}

func (m *pbUpsertWebhookOp) Reset()         { *m = pbUpsertWebhookOp{} }
func (m *pbUpsertWebhookOp) String() string { return oldproto.CompactTextString(m) }
func (*pbUpsertWebhookOp) ProtoMessage()    {}

type pbDeleteWebhookOp struct {
	ID string `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
}

func (m *pbDeleteWebhookOp) Reset()         { *m = pbDeleteWebhookOp{} }
func (m *pbDeleteWebhookOp) String() string { return oldproto.CompactTextString(m) }
func (*pbDeleteWebhookOp) ProtoMessage()    {}

type pbUpdateWebhookStatusOp struct {
	ID             string `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
	LastStatusCode int32  `protobuf:"varint,2,opt,name=last_status_code,json=lastStatusCode,proto3" json:"last_status_code,omitempty"`
	LastError      string `protobuf:"bytes,3,opt,name=last_error,json=lastError,proto3" json:"last_error,omitempty"`
	LastDeliveryAt string `protobuf:"bytes,4,opt,name=last_delivery_at,json=lastDeliveryAt,proto3" json:"last_delivery_at,omitempty"`
}

func (m *pbUpdateWebhookStatusOp) Reset()         { *m = pbUpdateWebhookStatusOp{} }
func (m *pbUpdateWebhookStatusOp) String() string { return oldproto.CompactTextString(m) }
func (*pbUpdateWebhookStatusOp) ProtoMessage()    {}

type pbSetNamespaceRateLimitOp struct {
	Name       string  `protobuf:"bytes,1,opt,name=name,proto3" json:"name,omitempty"`
	ReadRPS    float64 `protobuf:"fixed64,2,opt,name=read_rps,json=readRps,proto3" json:"read_rps,omitempty"`
	HasReadRPS bool    `protobuf:"varint,3,opt,name=has_read_rps,json=hasReadRps,proto3" json:"has_read_rps,omitempty"`
	ReadBurst  float64 `protobuf:"fixed64,4,opt,name=read_burst,json=readBurst,proto3" json:"read_burst,omitempty"`
	HasReadBurst bool  `protobuf:"varint,5,opt,name=has_read_burst,json=hasReadBurst,proto3" json:"has_read_burst,omitempty"`
	WriteRPS   float64 `protobuf:"fixed64,6,opt,name=write_rps,json=writeRps,proto3" json:"write_rps,omitempty"`
	HasWriteRPS bool   `protobuf:"varint,7,opt,name=has_write_rps,json=hasWriteRps,proto3" json:"has_write_rps,omitempty"`
	WriteBurst float64 `protobuf:"fixed64,8,opt,name=write_burst,json=writeBurst,proto3" json:"write_burst,omitempty"`
	HasWriteBurst bool `protobuf:"varint,9,opt,name=has_write_burst,json=hasWriteBurst,proto3" json:"has_write_burst,omitempty"`
}

func (m *pbSetNamespaceRateLimitOp) Reset()         { *m = pbSetNamespaceRateLimitOp{} }
func (m *pbSetNamespaceRateLimitOp) String() string { return oldproto.CompactTextString(m) }
func (*pbSetNamespaceRateLimitOp) ProtoMessage()    {}

// Enterprise toPB/fromPB conversion functions.

func toPBCreateNamespace(op CreateNamespaceOp) *pbCreateNamespaceOp {
	return &pbCreateNamespaceOp{Name: op.Name}
}
func fromPBCreateNamespace(op *pbCreateNamespaceOp) CreateNamespaceOp {
	return CreateNamespaceOp{Name: op.Name}
}

func toPBDeleteNamespace(op DeleteNamespaceOp) *pbDeleteNamespaceOp {
	return &pbDeleteNamespaceOp{Name: op.Name}
}
func fromPBDeleteNamespace(op *pbDeleteNamespaceOp) DeleteNamespaceOp {
	return DeleteNamespaceOp{Name: op.Name}
}

func toPBSetAuthRole(op SetAuthRoleOp) *pbSetAuthRoleOp {
	return &pbSetAuthRoleOp{Name: op.Name, Permissions: op.Permissions, Now: op.Now}
}
func fromPBSetAuthRole(op *pbSetAuthRoleOp) SetAuthRoleOp {
	return SetAuthRoleOp{Name: op.Name, Permissions: op.Permissions, Now: op.Now}
}

func toPBDeleteAuthRole(op DeleteAuthRoleOp) *pbDeleteAuthRoleOp {
	return &pbDeleteAuthRoleOp{Name: op.Name}
}
func fromPBDeleteAuthRole(op *pbDeleteAuthRoleOp) DeleteAuthRoleOp {
	return DeleteAuthRoleOp{Name: op.Name}
}

func toPBAssignAPIKeyRole(op AssignAPIKeyRoleOp) *pbAssignAPIKeyRoleOp {
	return &pbAssignAPIKeyRoleOp{KeyHash: op.KeyHash, Role: op.Role, Now: op.Now}
}
func fromPBAssignAPIKeyRole(op *pbAssignAPIKeyRoleOp) AssignAPIKeyRoleOp {
	return AssignAPIKeyRoleOp{KeyHash: op.KeyHash, Role: op.Role, Now: op.Now}
}

func toPBUnassignAPIKeyRole(op UnassignAPIKeyRoleOp) *pbUnassignAPIKeyRoleOp {
	return &pbUnassignAPIKeyRoleOp{KeyHash: op.KeyHash, Role: op.Role}
}
func fromPBUnassignAPIKeyRole(op *pbUnassignAPIKeyRoleOp) UnassignAPIKeyRoleOp {
	return UnassignAPIKeyRoleOp{KeyHash: op.KeyHash, Role: op.Role}
}

func toPBSetSSOSettings(op SetSSOSettingsOp) *pbSetSSOSettingsOp {
	return &pbSetSSOSettingsOp{
		Provider:      op.Provider,
		OIDCIssuerURL: op.OIDCIssuerURL,
		OIDCClientID:  op.OIDCClientID,
		SAMLEnabled:   int32(op.SAMLEnabled),
		Now:           op.Now,
	}
}
func fromPBSetSSOSettings(op *pbSetSSOSettingsOp) SetSSOSettingsOp {
	return SetSSOSettingsOp{
		Provider:      op.Provider,
		OIDCIssuerURL: op.OIDCIssuerURL,
		OIDCClientID:  op.OIDCClientID,
		SAMLEnabled:   int(op.SAMLEnabled),
		Now:           op.Now,
	}
}

func toPBUpsertAPIKey(op UpsertAPIKeyOp) *pbUpsertAPIKeyOp {
	return &pbUpsertAPIKeyOp{
		KeyHash:    op.KeyHash,
		Name:       op.Name,
		Namespace:  op.Namespace,
		Role:       op.Role,
		QueueScope: op.QueueScope,
		Enabled:    int32(op.Enabled),
		CreatedAt:  op.CreatedAt,
		ExpiresAt:  op.ExpiresAt,
	}
}
func fromPBUpsertAPIKey(op *pbUpsertAPIKeyOp) UpsertAPIKeyOp {
	return UpsertAPIKeyOp{
		KeyHash:    op.KeyHash,
		Name:       op.Name,
		Namespace:  op.Namespace,
		Role:       op.Role,
		QueueScope: op.QueueScope,
		Enabled:    int(op.Enabled),
		CreatedAt:  op.CreatedAt,
		ExpiresAt:  op.ExpiresAt,
	}
}

func toPBDeleteAPIKey(op DeleteAPIKeyOp) *pbDeleteAPIKeyOp {
	return &pbDeleteAPIKeyOp{KeyHash: op.KeyHash}
}
func fromPBDeleteAPIKey(op *pbDeleteAPIKeyOp) DeleteAPIKeyOp {
	return DeleteAPIKeyOp{KeyHash: op.KeyHash}
}

func toPBInsertAuditLog(op InsertAuditLogOp) *pbInsertAuditLogOp {
	return &pbInsertAuditLogOp{
		Namespace:  op.Namespace,
		Principal:  op.Principal,
		Role:       op.Role,
		Method:     op.Method,
		Path:       op.Path,
		StatusCode: int32(op.StatusCode),
		Metadata:   op.Metadata,
		CreatedAt:  op.CreatedAt,
	}
}
func fromPBInsertAuditLog(op *pbInsertAuditLogOp) InsertAuditLogOp {
	return InsertAuditLogOp{
		Namespace:  op.Namespace,
		Principal:  op.Principal,
		Role:       op.Role,
		Method:     op.Method,
		Path:       op.Path,
		StatusCode: int(op.StatusCode),
		Metadata:   op.Metadata,
		CreatedAt:  op.CreatedAt,
	}
}

func toPBUpdateAPIKeyUsed(op UpdateAPIKeyUsedOp) *pbUpdateAPIKeyUsedOp {
	return &pbUpdateAPIKeyUsedOp{KeyHash: op.KeyHash, Now: op.Now}
}
func fromPBUpdateAPIKeyUsed(op *pbUpdateAPIKeyUsedOp) UpdateAPIKeyUsedOp {
	return UpdateAPIKeyUsedOp{KeyHash: op.KeyHash, Now: op.Now}
}

func toPBUpsertWebhook(op UpsertWebhookOp) *pbUpsertWebhookOp {
	return &pbUpsertWebhookOp{
		ID:         op.ID,
		URL:        op.URL,
		Events:     op.Events,
		Secret:     op.Secret,
		Enabled:    int32(op.Enabled),
		RetryLimit: int32(op.RetryLimit),
	}
}
func fromPBUpsertWebhook(op *pbUpsertWebhookOp) UpsertWebhookOp {
	return UpsertWebhookOp{
		ID:         op.ID,
		URL:        op.URL,
		Events:     op.Events,
		Secret:     op.Secret,
		Enabled:    int(op.Enabled),
		RetryLimit: int(op.RetryLimit),
	}
}

func toPBDeleteWebhook(op DeleteWebhookOp) *pbDeleteWebhookOp {
	return &pbDeleteWebhookOp{ID: op.ID}
}
func fromPBDeleteWebhook(op *pbDeleteWebhookOp) DeleteWebhookOp {
	return DeleteWebhookOp{ID: op.ID}
}

func toPBUpdateWebhookStatus(op UpdateWebhookStatusOp) *pbUpdateWebhookStatusOp {
	return &pbUpdateWebhookStatusOp{
		ID:             op.ID,
		LastStatusCode: int32(op.LastStatusCode),
		LastError:      op.LastError,
		LastDeliveryAt: op.LastDeliveryAt,
	}
}
func fromPBUpdateWebhookStatus(op *pbUpdateWebhookStatusOp) UpdateWebhookStatusOp {
	return UpdateWebhookStatusOp{
		ID:             op.ID,
		LastStatusCode: int(op.LastStatusCode),
		LastError:      op.LastError,
		LastDeliveryAt: op.LastDeliveryAt,
	}
}

func toPBSetNamespaceRateLimit(op SetNamespaceRateLimitOp) *pbSetNamespaceRateLimitOp {
	pb := &pbSetNamespaceRateLimitOp{Name: op.Name}
	if op.ReadRPS != nil {
		pb.ReadRPS = *op.ReadRPS
		pb.HasReadRPS = true
	}
	if op.ReadBurst != nil {
		pb.ReadBurst = *op.ReadBurst
		pb.HasReadBurst = true
	}
	if op.WriteRPS != nil {
		pb.WriteRPS = *op.WriteRPS
		pb.HasWriteRPS = true
	}
	if op.WriteBurst != nil {
		pb.WriteBurst = *op.WriteBurst
		pb.HasWriteBurst = true
	}
	return pb
}
func fromPBSetNamespaceRateLimit(op *pbSetNamespaceRateLimitOp) SetNamespaceRateLimitOp {
	out := SetNamespaceRateLimitOp{Name: op.Name}
	if op.HasReadRPS {
		v := op.ReadRPS
		out.ReadRPS = &v
	}
	if op.HasReadBurst {
		v := op.ReadBurst
		out.ReadBurst = &v
	}
	if op.HasWriteRPS {
		v := op.WriteRPS
		out.WriteRPS = &v
	}
	if op.HasWriteBurst {
		v := op.WriteBurst
		out.WriteBurst = &v
	}
	return out
}
