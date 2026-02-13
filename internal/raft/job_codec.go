package raft

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	oldproto "github.com/golang/protobuf/proto"
	"github.com/user/jobbie/internal/store"
)

var jobProtoPrefix = []byte{0x4a, 0x42, 0x31} // "JB1"

type pbJobDoc struct {
	ID                    string  `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
	Queue                 string  `protobuf:"bytes,2,opt,name=queue,proto3" json:"queue,omitempty"`
	State                 string  `protobuf:"bytes,3,opt,name=state,proto3" json:"state,omitempty"`
	Payload               []byte  `protobuf:"bytes,4,opt,name=payload,proto3" json:"payload,omitempty"`
	Priority              int32   `protobuf:"varint,5,opt,name=priority,proto3" json:"priority,omitempty"`
	Attempt               int32   `protobuf:"varint,6,opt,name=attempt,proto3" json:"attempt,omitempty"`
	MaxRetries            int32   `protobuf:"varint,7,opt,name=max_retries,json=maxRetries,proto3" json:"max_retries,omitempty"`
	RetryBackoff          string  `protobuf:"bytes,8,opt,name=retry_backoff,json=retryBackoff,proto3" json:"retry_backoff,omitempty"`
	RetryBaseDelay        int32   `protobuf:"varint,9,opt,name=retry_base_delay,json=retryBaseDelay,proto3" json:"retry_base_delay,omitempty"`
	RetryMaxDelay         int32   `protobuf:"varint,10,opt,name=retry_max_delay,json=retryMaxDelay,proto3" json:"retry_max_delay,omitempty"`
	UniqueKey             string  `protobuf:"bytes,11,opt,name=unique_key,json=uniqueKey,proto3" json:"unique_key,omitempty"`
	HasUniqueKey          bool    `protobuf:"varint,12,opt,name=has_unique_key,json=hasUniqueKey,proto3" json:"has_unique_key,omitempty"`
	BatchID               string  `protobuf:"bytes,13,opt,name=batch_id,json=batchId,proto3" json:"batch_id,omitempty"`
	HasBatchID            bool    `protobuf:"varint,14,opt,name=has_batch_id,json=hasBatchID,proto3" json:"has_batch_id,omitempty"`
	WorkerID              string  `protobuf:"bytes,15,opt,name=worker_id,json=workerId,proto3" json:"worker_id,omitempty"`
	HasWorkerID           bool    `protobuf:"varint,16,opt,name=has_worker_id,json=hasWorkerID,proto3" json:"has_worker_id,omitempty"`
	Hostname              string  `protobuf:"bytes,17,opt,name=hostname,proto3" json:"hostname,omitempty"`
	HasHostname           bool    `protobuf:"varint,18,opt,name=has_hostname,json=hasHostname,proto3" json:"has_hostname,omitempty"`
	Tags                  []byte  `protobuf:"bytes,19,opt,name=tags,proto3" json:"tags,omitempty"`
	Progress              []byte  `protobuf:"bytes,20,opt,name=progress,proto3" json:"progress,omitempty"`
	Checkpoint            []byte  `protobuf:"bytes,21,opt,name=checkpoint,proto3" json:"checkpoint,omitempty"`
	Result                []byte  `protobuf:"bytes,22,opt,name=result,proto3" json:"result,omitempty"`
	LeaseExpiresNs        int64   `protobuf:"varint,23,opt,name=lease_expires_ns,json=leaseExpiresNs,proto3" json:"lease_expires_ns,omitempty"`
	HasLease              bool    `protobuf:"varint,24,opt,name=has_lease,json=hasLease,proto3" json:"has_lease,omitempty"`
	ScheduledAtNs         int64   `protobuf:"varint,25,opt,name=scheduled_at_ns,json=scheduledAtNs,proto3" json:"scheduled_at_ns,omitempty"`
	HasScheduled          bool    `protobuf:"varint,26,opt,name=has_scheduled,json=hasScheduled,proto3" json:"has_scheduled,omitempty"`
	ExpireAtNs            int64   `protobuf:"varint,27,opt,name=expire_at_ns,json=expireAtNs,proto3" json:"expire_at_ns,omitempty"`
	HasExpire             bool    `protobuf:"varint,28,opt,name=has_expire,json=hasExpire,proto3" json:"has_expire,omitempty"`
	CreatedAtNs           int64   `protobuf:"varint,29,opt,name=created_at_ns,json=createdAtNs,proto3" json:"created_at_ns,omitempty"`
	StartedAtNs           int64   `protobuf:"varint,30,opt,name=started_at_ns,json=startedAtNs,proto3" json:"started_at_ns,omitempty"`
	HasStarted            bool    `protobuf:"varint,31,opt,name=has_started,json=hasStarted,proto3" json:"has_started,omitempty"`
	CompletedAtNs         int64   `protobuf:"varint,32,opt,name=completed_at_ns,json=completedAtNs,proto3" json:"completed_at_ns,omitempty"`
	HasCompleted          bool    `protobuf:"varint,33,opt,name=has_completed,json=hasCompleted,proto3" json:"has_completed,omitempty"`
	FailedAtNs            int64   `protobuf:"varint,34,opt,name=failed_at_ns,json=failedAtNs,proto3" json:"failed_at_ns,omitempty"`
	HasFailed             bool    `protobuf:"varint,35,opt,name=has_failed,json=hasFailed,proto3" json:"has_failed,omitempty"`
	AgentMaxIterations    int32   `protobuf:"varint,36,opt,name=agent_max_iterations,json=agentMaxIterations,proto3" json:"agent_max_iterations,omitempty"`
	AgentMaxCostUsd       float64 `protobuf:"fixed64,37,opt,name=agent_max_cost_usd,json=agentMaxCostUsd,proto3" json:"agent_max_cost_usd,omitempty"`
	AgentIterationTimeout string  `protobuf:"bytes,38,opt,name=agent_iteration_timeout,json=agentIterationTimeout,proto3" json:"agent_iteration_timeout,omitempty"`
	AgentIteration        int32   `protobuf:"varint,39,opt,name=agent_iteration,json=agentIteration,proto3" json:"agent_iteration,omitempty"`
	AgentTotalCostUsd     float64 `protobuf:"fixed64,40,opt,name=agent_total_cost_usd,json=agentTotalCostUsd,proto3" json:"agent_total_cost_usd,omitempty"`
	HasAgent              bool    `protobuf:"varint,41,opt,name=has_agent,json=hasAgent,proto3" json:"has_agent,omitempty"`
	HoldReason            string  `protobuf:"bytes,42,opt,name=hold_reason,json=holdReason,proto3" json:"hold_reason,omitempty"`
	HasHoldReason         bool    `protobuf:"varint,43,opt,name=has_hold_reason,json=hasHoldReason,proto3" json:"has_hold_reason,omitempty"`
	ResultSchema          []byte  `protobuf:"bytes,44,opt,name=result_schema,json=resultSchema,proto3" json:"result_schema,omitempty"`
	ParentID              string  `protobuf:"bytes,45,opt,name=parent_id,json=parentId,proto3" json:"parent_id,omitempty"`
	HasParentID           bool    `protobuf:"varint,46,opt,name=has_parent_id,json=hasParentId,proto3" json:"has_parent_id,omitempty"`
	ChainID               string  `protobuf:"bytes,47,opt,name=chain_id,json=chainId,proto3" json:"chain_id,omitempty"`
	HasChainID            bool    `protobuf:"varint,48,opt,name=has_chain_id,json=hasChainId,proto3" json:"has_chain_id,omitempty"`
	ChainStep             int32   `protobuf:"varint,49,opt,name=chain_step,json=chainStep,proto3" json:"chain_step,omitempty"`
	HasChainStep          bool    `protobuf:"varint,50,opt,name=has_chain_step,json=hasChainStep,proto3" json:"has_chain_step,omitempty"`
	ChainConfig           []byte  `protobuf:"bytes,51,opt,name=chain_config,json=chainConfig,proto3" json:"chain_config,omitempty"`
	ProviderError         bool    `protobuf:"varint,52,opt,name=provider_error,json=providerError,proto3" json:"provider_error,omitempty"`
	Routing               []byte  `protobuf:"bytes,53,opt,name=routing,proto3" json:"routing,omitempty"`
	RoutingTarget         string  `protobuf:"bytes,54,opt,name=routing_target,json=routingTarget,proto3" json:"routing_target,omitempty"`
	HasRoutingTarget      bool    `protobuf:"varint,55,opt,name=has_routing_target,json=hasRoutingTarget,proto3" json:"has_routing_target,omitempty"`
	RoutingIndex          int32   `protobuf:"varint,56,opt,name=routing_index,json=routingIndex,proto3" json:"routing_index,omitempty"`
}

func (m *pbJobDoc) Reset()         { *m = pbJobDoc{} }
func (m *pbJobDoc) String() string { return oldproto.CompactTextString(m) }
func (*pbJobDoc) ProtoMessage()    {}

func encodeJobDoc(job store.Job) ([]byte, error) {
	p := &pbJobDoc{
		ID:             job.ID,
		Queue:          job.Queue,
		State:          job.State,
		Payload:        append([]byte(nil), job.Payload...),
		Priority:       int32(job.Priority),
		Attempt:        int32(job.Attempt),
		MaxRetries:     int32(job.MaxRetries),
		RetryBackoff:   job.RetryBackoff,
		RetryBaseDelay: int32(job.RetryBaseDelay),
		RetryMaxDelay:  int32(job.RetryMaxDelay),
		Tags:           append([]byte(nil), job.Tags...),
		Progress:       append([]byte(nil), job.Progress...),
		Checkpoint:     append([]byte(nil), job.Checkpoint...),
		Result:         append([]byte(nil), job.Result...),
		ResultSchema:   append([]byte(nil), job.ResultSchema...),
		CreatedAtNs:    job.CreatedAt.UnixNano(),
		ProviderError:  job.ProviderError,
		RoutingIndex:   int32(job.RoutingIndex),
	}
	if job.Routing != nil {
		b, _ := json.Marshal(job.Routing)
		p.Routing = b
	}
	if job.UniqueKey != nil {
		p.HasUniqueKey = true
		p.UniqueKey = *job.UniqueKey
	}
	if job.BatchID != nil {
		p.HasBatchID = true
		p.BatchID = *job.BatchID
	}
	if job.WorkerID != nil {
		p.HasWorkerID = true
		p.WorkerID = *job.WorkerID
	}
	if job.Hostname != nil {
		p.HasHostname = true
		p.Hostname = *job.Hostname
	}
	if job.LeaseExpiresAt != nil {
		p.HasLease = true
		p.LeaseExpiresNs = job.LeaseExpiresAt.UnixNano()
	}
	if job.ScheduledAt != nil {
		p.HasScheduled = true
		p.ScheduledAtNs = job.ScheduledAt.UnixNano()
	}
	if job.ExpireAt != nil {
		p.HasExpire = true
		p.ExpireAtNs = job.ExpireAt.UnixNano()
	}
	if job.StartedAt != nil {
		p.HasStarted = true
		p.StartedAtNs = job.StartedAt.UnixNano()
	}
	if job.CompletedAt != nil {
		p.HasCompleted = true
		p.CompletedAtNs = job.CompletedAt.UnixNano()
	}
	if job.FailedAt != nil {
		p.HasFailed = true
		p.FailedAtNs = job.FailedAt.UnixNano()
	}
	if job.Agent != nil {
		p.HasAgent = true
		p.AgentMaxIterations = int32(job.Agent.MaxIterations)
		p.AgentMaxCostUsd = job.Agent.MaxCostUSD
		p.AgentIterationTimeout = job.Agent.IterationTimeout
		p.AgentIteration = int32(job.Agent.Iteration)
		p.AgentTotalCostUsd = job.Agent.TotalCostUSD
	}
	if job.HoldReason != nil {
		p.HasHoldReason = true
		p.HoldReason = *job.HoldReason
	}
	if job.ParentID != nil {
		p.HasParentID = true
		p.ParentID = *job.ParentID
	}
	if job.ChainID != nil {
		p.HasChainID = true
		p.ChainID = *job.ChainID
	}
	if job.ChainStep != nil {
		p.HasChainStep = true
		p.ChainStep = int32(*job.ChainStep)
	}
	if len(job.ChainConfig) > 0 {
		p.ChainConfig = append([]byte(nil), job.ChainConfig...)
	}
	if job.RoutingTarget != nil {
		p.HasRoutingTarget = true
		p.RoutingTarget = *job.RoutingTarget
	}
	wire, err := oldproto.Marshal(p)
	if err != nil {
		return nil, err
	}
	return append(append([]byte{}, jobProtoPrefix...), wire...), nil
}

func decodeJobDoc(data []byte, out *store.Job) error {
	if bytes.HasPrefix(data, jobProtoPrefix) {
		var p pbJobDoc
		if err := oldproto.Unmarshal(data[len(jobProtoPrefix):], &p); err != nil {
			return fmt.Errorf("unmarshal protobuf job: %w", err)
		}
		*out = store.Job{
			ID:             p.ID,
			Queue:          p.Queue,
			State:          p.State,
			Payload:        append([]byte(nil), p.Payload...),
			Priority:       int(p.Priority),
			Attempt:        int(p.Attempt),
			MaxRetries:     int(p.MaxRetries),
			RetryBackoff:   p.RetryBackoff,
			RetryBaseDelay: int(p.RetryBaseDelay),
			RetryMaxDelay:  int(p.RetryMaxDelay),
			Tags:           append([]byte(nil), p.Tags...),
			Progress:       append([]byte(nil), p.Progress...),
			Checkpoint:     append([]byte(nil), p.Checkpoint...),
			Result:         append([]byte(nil), p.Result...),
			ResultSchema:   append([]byte(nil), p.ResultSchema...),
			CreatedAt:      time.Unix(0, p.CreatedAtNs).UTC(),
			ProviderError:  p.ProviderError,
			RoutingIndex:   int(p.RoutingIndex),
		}
		if len(p.Routing) > 0 {
			var r store.RoutingConfig
			if err := json.Unmarshal(p.Routing, &r); err == nil {
				out.Routing = &r
			}
		}
		if p.HasUniqueKey {
			v := p.UniqueKey
			out.UniqueKey = &v
		}
		if p.HasBatchID {
			v := p.BatchID
			out.BatchID = &v
		}
		if p.HasWorkerID {
			v := p.WorkerID
			out.WorkerID = &v
		}
		if p.HasHostname {
			v := p.Hostname
			out.Hostname = &v
		}
		if p.HasLease {
			t := time.Unix(0, p.LeaseExpiresNs).UTC()
			out.LeaseExpiresAt = &t
		}
		if p.HasScheduled {
			t := time.Unix(0, p.ScheduledAtNs).UTC()
			out.ScheduledAt = &t
		}
		if p.HasExpire {
			t := time.Unix(0, p.ExpireAtNs).UTC()
			out.ExpireAt = &t
		}
		if p.HasStarted {
			t := time.Unix(0, p.StartedAtNs).UTC()
			out.StartedAt = &t
		}
		if p.HasCompleted {
			t := time.Unix(0, p.CompletedAtNs).UTC()
			out.CompletedAt = &t
		}
		if p.HasFailed {
			t := time.Unix(0, p.FailedAtNs).UTC()
			out.FailedAt = &t
		}
		if p.HasAgent {
			out.Agent = &store.AgentState{
				MaxIterations:    int(p.AgentMaxIterations),
				MaxCostUSD:       p.AgentMaxCostUsd,
				IterationTimeout: p.AgentIterationTimeout,
				Iteration:        int(p.AgentIteration),
				TotalCostUSD:     p.AgentTotalCostUsd,
			}
		}
		if p.HasHoldReason {
			v := p.HoldReason
			out.HoldReason = &v
		}
		if p.HasParentID {
			v := p.ParentID
			out.ParentID = &v
		}
		if p.HasChainID {
			v := p.ChainID
			out.ChainID = &v
		}
		if p.HasChainStep {
			v := int(p.ChainStep)
			out.ChainStep = &v
		}
		if len(p.ChainConfig) > 0 {
			out.ChainConfig = append([]byte(nil), p.ChainConfig...)
		}
		if p.HasRoutingTarget {
			v := p.RoutingTarget
			out.RoutingTarget = &v
		}
		return nil
	}
	return json.Unmarshal(data, out)
}
