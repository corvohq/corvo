package rpcconnect

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"connectrpc.com/connect"
	jobbiev1 "github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1"
	"github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1/jobbiev1connect"
	"github.com/user/jobbie/internal/store"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func mapStoreError(err error) error {
	if store.IsOverloadedError(err) {
		if ms, ok := store.OverloadRetryAfterMs(err); ok && ms > 0 {
			return connect.NewError(connect.CodeResourceExhausted, fmt.Errorf("%s (retry_after_ms=%d)", err.Error(), ms))
		}
		return connect.NewError(connect.CodeResourceExhausted, err)
	}
	return connect.NewError(connect.CodeInvalidArgument, err)
}

// Server implements the Connect WorkerService API.
type Server struct {
	store *store.Store
}

func longPollTimeout(lease int) time.Duration {
	if lease <= 0 {
		lease = 30
	}
	if lease > 60 {
		lease = 60
	}
	return time.Duration(lease) * time.Second
}

func waitForFetch(ctx context.Context, timeout time.Duration, poll func() (bool, error)) error {
	deadline := time.Now().Add(timeout)
	for {
		ok, err := poll()
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
		if time.Now().After(deadline) {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// NewHandler creates a Connect HTTP handler for worker lifecycle RPCs.
func NewHandler(s *store.Store) (string, http.Handler) {
	return jobbiev1connect.NewWorkerServiceHandler(&Server{store: s})
}

func (s *Server) Enqueue(ctx context.Context, req *connect.Request[jobbiev1.EnqueueRequest]) (*connect.Response[jobbiev1.EnqueueResponse], error) {
	payload := strings.TrimSpace(req.Msg.GetPayloadJson())
	if payload == "" {
		payload = `{}`
	}

	result, err := s.store.Enqueue(store.EnqueueRequest{
		Queue:   req.Msg.GetQueue(),
		Payload: json.RawMessage(payload),
	})
	if err != nil {
		return nil, mapStoreError(err)
	}

	return connect.NewResponse(&jobbiev1.EnqueueResponse{
		JobId:          result.JobID,
		Status:         result.Status,
		UniqueExisting: result.UniqueExisting,
	}), nil
}

func (s *Server) Fetch(ctx context.Context, req *connect.Request[jobbiev1.FetchRequest]) (*connect.Response[jobbiev1.FetchResponse], error) {
	var result *store.FetchResult
	fetchReq := store.FetchRequest{
		Queues:        req.Msg.GetQueues(),
		WorkerID:      req.Msg.GetWorkerId(),
		Hostname:      req.Msg.GetHostname(),
		LeaseDuration: int(req.Msg.GetLeaseDuration()),
	}
	err := waitForFetch(ctx, longPollTimeout(fetchReq.LeaseDuration), func() (bool, error) {
		r, err := s.store.Fetch(fetchReq)
		if err != nil {
			return false, err
		}
		result = r
		return result != nil, nil
	})
	if err != nil {
		return nil, mapStoreError(err)
	}
	if result == nil {
		return connect.NewResponse(&jobbiev1.FetchResponse{Found: false}), nil
	}

	resp := &jobbiev1.FetchResponse{
		Found:          true,
		JobId:          result.JobID,
		Queue:          result.Queue,
		PayloadJson:    string(result.Payload),
		Attempt:        int32(result.Attempt),
		MaxRetries:     int32(result.MaxRetries),
		LeaseDuration:  int32(result.LeaseDuration),
		CheckpointJson: string(result.Checkpoint),
		TagsJson:       string(result.Tags),
	}
	return connect.NewResponse(resp), nil
}

func (s *Server) FetchBatch(ctx context.Context, req *connect.Request[jobbiev1.FetchBatchRequest]) (*connect.Response[jobbiev1.FetchBatchResponse], error) {
	count := int(req.Msg.GetCount())
	if count <= 0 {
		count = 1
	}
	fetchReq := store.FetchRequest{
		Queues:        req.Msg.GetQueues(),
		WorkerID:      req.Msg.GetWorkerId(),
		Hostname:      req.Msg.GetHostname(),
		LeaseDuration: int(req.Msg.GetLeaseDuration()),
	}
	var jobs []store.FetchResult
	err := waitForFetch(ctx, longPollTimeout(fetchReq.LeaseDuration), func() (bool, error) {
		r, err := s.store.FetchBatch(fetchReq, count)
		if err != nil {
			return false, err
		}
		jobs = r
		return len(jobs) > 0, nil
	})
	if err != nil {
		return nil, mapStoreError(err)
	}

	respJobs := make([]*jobbiev1.FetchBatchJob, 0, len(jobs))
	for _, j := range jobs {
		respJobs = append(respJobs, &jobbiev1.FetchBatchJob{
			JobId:          j.JobID,
			Queue:          j.Queue,
			PayloadJson:    string(j.Payload),
			Attempt:        int32(j.Attempt),
			MaxRetries:     int32(j.MaxRetries),
			LeaseDuration:  int32(j.LeaseDuration),
			CheckpointJson: string(j.Checkpoint),
			TagsJson:       string(j.Tags),
		})
	}
	return connect.NewResponse(&jobbiev1.FetchBatchResponse{Jobs: respJobs}), nil
}

func (s *Server) Ack(ctx context.Context, req *connect.Request[jobbiev1.AckRequest]) (*connect.Response[jobbiev1.AckResponse], error) {
	resultJSON := strings.TrimSpace(req.Msg.GetResultJson())
	if resultJSON == "" {
		resultJSON = `{}`
	}
	if err := s.store.Ack(req.Msg.GetJobId(), json.RawMessage(resultJSON)); err != nil {
		return nil, mapStoreError(err)
	}
	return connect.NewResponse(&jobbiev1.AckResponse{}), nil
}

func (s *Server) AckBatch(ctx context.Context, req *connect.Request[jobbiev1.AckBatchRequest]) (*connect.Response[jobbiev1.AckBatchResponse], error) {
	items := req.Msg.GetItems()
	if len(items) == 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("items is required"))
	}
	acks := make([]store.AckOp, 0, len(items))
	for _, item := range items {
		jobID := strings.TrimSpace(item.GetJobId())
		if jobID == "" {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("job_id is required"))
		}
		resultJSON := strings.TrimSpace(item.GetResultJson())
		if resultJSON == "" {
			resultJSON = `{}`
		}
		acks = append(acks, store.AckOp{
			JobID:  jobID,
			Result: json.RawMessage(resultJSON),
		})
	}

	acked, err := s.store.AckBatch(acks)
	if err != nil {
		return nil, mapStoreError(err)
	}
	return connect.NewResponse(&jobbiev1.AckBatchResponse{Acked: int32(acked)}), nil
}

func (s *Server) StreamLifecycle(ctx context.Context, stream *connect.BidiStream[jobbiev1.LifecycleStreamRequest, jobbiev1.LifecycleStreamResponse]) error {
	for {
		req, err := stream.Receive()
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return connect.NewError(connect.CodeUnknown, fmt.Errorf("stream lifecycle receive: %w", err))
		}
		resp := &jobbiev1.LifecycleStreamResponse{
			RequestId: req.GetRequestId(),
		}

		if n := int(req.GetFetchCount()); n > 0 {
			fetchReq := store.FetchRequest{
				Queues:        req.GetQueues(),
				WorkerID:      req.GetWorkerId(),
				Hostname:      req.GetHostname(),
				LeaseDuration: int(req.GetLeaseDuration()),
			}
			var jobs []store.FetchResult
			err := waitForFetch(ctx, longPollTimeout(fetchReq.LeaseDuration), func() (bool, error) {
				r, err := s.store.FetchBatch(fetchReq, n)
				if err != nil {
					return false, err
				}
				jobs = r
				return len(jobs) > 0, nil
			})
			if err != nil {
				if store.IsOverloadedError(err) {
					resp.Error = "OVERLOADED: fetch: " + err.Error()
				} else {
					resp.Error = "fetch: " + err.Error()
				}
			} else {
				respJobs := make([]*jobbiev1.FetchBatchJob, 0, len(jobs))
				for _, j := range jobs {
					respJobs = append(respJobs, &jobbiev1.FetchBatchJob{
						JobId:          j.JobID,
						Queue:          j.Queue,
						PayloadJson:    string(j.Payload),
						Attempt:        int32(j.Attempt),
						MaxRetries:     int32(j.MaxRetries),
						LeaseDuration:  int32(j.LeaseDuration),
						CheckpointJson: string(j.Checkpoint),
						TagsJson:       string(j.Tags),
					})
				}
				resp.Jobs = respJobs
			}
		}

		if len(req.GetAcks()) > 0 {
			acks := make([]store.AckOp, 0, len(req.GetAcks()))
			for _, item := range req.GetAcks() {
				jobID := strings.TrimSpace(item.GetJobId())
				if jobID == "" {
					if resp.Error == "" {
						resp.Error = "ack: job_id is required"
					}
					continue
				}
				resultJSON := strings.TrimSpace(item.GetResultJson())
				if resultJSON == "" {
					resultJSON = `{}`
				}
				acks = append(acks, store.AckOp{
					JobID:  jobID,
					Result: json.RawMessage(resultJSON),
				})
			}
			if len(acks) > 0 {
				acked, err := s.store.AckBatch(acks)
				if err != nil {
					if resp.Error == "" {
						if store.IsOverloadedError(err) {
							resp.Error = "OVERLOADED: ack: " + err.Error()
						} else {
							resp.Error = "ack: " + err.Error()
						}
					}
				} else {
					resp.Acked = int32(acked)
				}
			}
		}

		if len(req.GetEnqueues()) > 0 {
			jobs := make([]store.EnqueueRequest, 0, len(req.GetEnqueues()))
			for _, item := range req.GetEnqueues() {
				queue := strings.TrimSpace(item.GetQueue())
				if queue == "" {
					if resp.Error == "" {
						resp.Error = "enqueue: queue is required"
					}
					continue
				}
				payload := strings.TrimSpace(item.GetPayloadJson())
				if payload == "" {
					payload = `{}`
				}
				jobs = append(jobs, store.EnqueueRequest{
					Queue:   queue,
					Payload: json.RawMessage(payload),
				})
			}
			if len(jobs) > 0 {
				enq, err := s.store.EnqueueBatch(store.BatchEnqueueRequest{Jobs: jobs})
				if err != nil {
					if resp.Error == "" {
						if store.IsOverloadedError(err) {
							resp.Error = "OVERLOADED: enqueue: " + err.Error()
						} else {
							resp.Error = "enqueue: " + err.Error()
						}
					}
				} else {
					resp.EnqueuedJobIds = append(resp.EnqueuedJobIds, enq.JobIDs...)
				}
			}
		}

		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

func (s *Server) Fail(ctx context.Context, req *connect.Request[jobbiev1.FailRequest]) (*connect.Response[jobbiev1.FailResponse], error) {
	result, err := s.store.Fail(req.Msg.GetJobId(), req.Msg.GetError(), req.Msg.GetBacktrace())
	if err != nil {
		return nil, mapStoreError(err)
	}

	resp := &jobbiev1.FailResponse{
		Status:            result.Status,
		AttemptsRemaining: int32(result.AttemptsRemaining),
	}
	if result.NextAttemptAt != nil {
		resp.NextAttemptAt = timestamppb.New(*result.NextAttemptAt)
	}
	return connect.NewResponse(resp), nil
}

func (s *Server) Heartbeat(ctx context.Context, req *connect.Request[jobbiev1.HeartbeatRequest]) (*connect.Response[jobbiev1.HeartbeatResponse], error) {
	hbReq := store.HeartbeatRequest{Jobs: map[string]store.HeartbeatJobUpdate{}}

	for jobID, update := range req.Msg.GetJobs() {
		jobUpdate := store.HeartbeatJobUpdate{}
		if p := strings.TrimSpace(update.GetProgressJson()); p != "" {
			var m map[string]interface{}
			if err := json.Unmarshal([]byte(p), &m); err != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid progress_json for %s: %w", jobID, err))
			}
			jobUpdate.Progress = m
		}
		if c := strings.TrimSpace(update.GetCheckpointJson()); c != "" {
			var m map[string]interface{}
			if err := json.Unmarshal([]byte(c), &m); err != nil {
				return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid checkpoint_json for %s: %w", jobID, err))
			}
			jobUpdate.Checkpoint = m
		}
		hbReq.Jobs[jobID] = jobUpdate
	}

	result, err := s.store.Heartbeat(hbReq)
	if err != nil {
		if store.IsOverloadedError(err) {
			return nil, connect.NewError(connect.CodeResourceExhausted, err)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	resp := &jobbiev1.HeartbeatResponse{Jobs: map[string]*jobbiev1.HeartbeatJobResponse{}}
	for jobID, status := range result.Jobs {
		resp.Jobs[jobID] = &jobbiev1.HeartbeatJobResponse{Status: status.Status}
	}
	return connect.NewResponse(resp), nil
}
