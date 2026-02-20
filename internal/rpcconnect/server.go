package rpcconnect

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"connectrpc.com/connect"
	corvov1 "github.com/corvohq/proto/gen/corvo/v1"
	"github.com/corvohq/proto/gen/corvo/v1/corvov1connect"
	"github.com/corvohq/corvo/internal/store"
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

// StreamConfig controls per-stream rate limiting and circuit-breaking.
type StreamConfig struct {
	MaxFramesPerSec int           // Max frames/sec per stream; 0 = unlimited (default 500)
	StrikeLimit     int           // Consecutive errors before closing stream (default 10)
	StrikeDelay     time.Duration // Progressive delay per strike (default 5ms)
	MaxOpenStreams  int           // Max concurrently open lifecycle streams (default 4096)
	MaxInFlight     int           // Max concurrently processing lifecycle frames (default 2048)
	AcquireTimeout  time.Duration // Max wait to acquire in-flight slot; <=0 blocks until available
	FetchPollInterval  time.Duration // Unary Fetch/FetchBatch long-poll retry interval (default 100ms)
	IdleFetchSleep     time.Duration // Stream sleep when fetch returns zero jobs (default 100ms)
	DisableCompression bool          // Disable gzip compression on ConnectRPC responses
}

func (c StreamConfig) withDefaults() StreamConfig {
	if c.MaxFramesPerSec < 0 {
		c.MaxFramesPerSec = 500
	}
	if c.StrikeLimit <= 0 {
		c.StrikeLimit = 10
	}
	if c.StrikeDelay <= 0 {
		c.StrikeDelay = 5 * time.Millisecond
	}
	// 0 means unlimited. In-flight frame gating is the primary overload
	// control; hard stream caps can trigger reconnect storms.
	if c.MaxInFlight <= 0 {
		c.MaxInFlight = 2048
	}
	if c.FetchPollInterval <= 0 {
		c.FetchPollInterval = 100 * time.Millisecond
	}
	if c.IdleFetchSleep <= 0 {
		c.IdleFetchSleep = 100 * time.Millisecond
	}
	return c
}

// LeaderCheck reports whether this node is the Raft leader.
type LeaderCheck interface {
	IsLeader() bool
	LeaderHTTPURL() string // e.g. "http://10.0.0.2:8080", or "" if unknown
}

// StreamStats exposes lifecycle stream metrics for Prometheus scraping.
type StreamStats struct {
	OpenStreams     int64
	MaxOpenStreams  int
	InFlight       int
	MaxInFlight    int
	FramesTotal    uint64
	StreamsTotal   uint64
	OverloadTotal  uint64
	IdleFetchTotal uint64
}

// Server implements the Connect WorkerService API.
type Server struct {
	store         *store.Store
	version       string
	streamCfg     StreamConfig
	frameSem      chan struct{}
	openCount     atomic.Int64
	leaderCheck   LeaderCheck
	framesTotal    atomic.Uint64
	streamsTotal   atomic.Uint64
	overloadTotal  atomic.Uint64
	idleFetchTotal atomic.Uint64
}

// Stats returns a snapshot of lifecycle stream metrics.
func (s *Server) Stats() StreamStats {
	return StreamStats{
		OpenStreams:    s.openCount.Load(),
		MaxOpenStreams: s.streamCfg.MaxOpenStreams,
		InFlight:      len(s.frameSem),
		MaxInFlight:   s.streamCfg.MaxInFlight,
		FramesTotal:   s.framesTotal.Load(),
		StreamsTotal:  s.streamsTotal.Load(),
		OverloadTotal:  s.overloadTotal.Load(),
		IdleFetchTotal: s.idleFetchTotal.Load(),
	}
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

func waitForFetch(ctx context.Context, timeout time.Duration, pollInterval time.Duration, poll func() (bool, error)) error {
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
		case <-time.After(pollInterval):
		}
	}
}

// NewHandler creates a Connect HTTP handler for worker lifecycle RPCs.
func NewHandler(s *store.Store, opts ...func(*Server)) (string, http.Handler, *Server) {
	srv := &Server{store: s}
	for _, o := range opts {
		o(srv)
	}
	srv.streamCfg = srv.streamCfg.withDefaults()
	srv.frameSem = make(chan struct{}, srv.streamCfg.MaxInFlight)
	var handlerOpts []connect.HandlerOption
	if srv.streamCfg.DisableCompression {
		handlerOpts = append(handlerOpts, connect.WithCompression("gzip", nil, nil))
	}
	handlerOpts = append(handlerOpts, connect.WithInterceptors(sdkHeaderInterceptor()))
	path, handler := corvov1connect.NewWorkerServiceHandler(srv, handlerOpts...)
	return path, handler, srv
}

// WithStreamConfig sets the per-stream rate limit / circuit-break config.
func WithStreamConfig(cfg StreamConfig) func(*Server) {
	return func(s *Server) { s.streamCfg = cfg }
}

// WithVersion sets the server version returned by GetServerInfo.
func WithVersion(v string) func(*Server) {
	return func(s *Server) { s.version = v }
}

// WithLeaderCheck enables per-stream leadership verification.
func WithLeaderCheck(lc LeaderCheck) func(*Server) {
	return func(s *Server) { s.leaderCheck = lc }
}

// checkLeader returns a NOT_LEADER response if this node is not the leader,
// or nil if the node is the leader (or no LeaderCheck is configured).
func (s *Server) checkLeader(requestID uint64) *corvov1.LifecycleStreamResponse {
	if s.leaderCheck == nil || s.leaderCheck.IsLeader() {
		return nil
	}
	return &corvov1.LifecycleStreamResponse{
		RequestId:  requestID,
		Error:      "NOT_LEADER",
		LeaderAddr: s.leaderCheck.LeaderHTTPURL(),
	}
}

func (s *Server) Enqueue(ctx context.Context, req *connect.Request[corvov1.EnqueueRequest]) (*connect.Response[corvov1.EnqueueResponse], error) {
	payload := strings.TrimSpace(req.Msg.GetPayloadJson())
	if payload == "" {
		payload = `{}`
	}

	result, err := s.store.Enqueue(store.EnqueueRequest{
		Queue:   req.Msg.GetQueue(),
		Payload: json.RawMessage(payload),
		Agent:   agentConfigFromPB(req.Msg.GetAgent()),
	})
	if err != nil {
		return nil, mapStoreError(err)
	}

	return connect.NewResponse(&corvov1.EnqueueResponse{
		JobId:          result.JobID,
		Status:         result.Status,
		UniqueExisting: result.UniqueExisting,
	}), nil
}

func (s *Server) Fetch(ctx context.Context, req *connect.Request[corvov1.FetchRequest]) (*connect.Response[corvov1.FetchResponse], error) {
	var result *store.FetchResult
	fetchReq := store.FetchRequest{
		Queues:        req.Msg.GetQueues(),
		WorkerID:      req.Msg.GetWorkerId(),
		Hostname:      req.Msg.GetHostname(),
		LeaseDuration: int(req.Msg.GetLeaseDuration()),
	}
	err := waitForFetch(ctx, longPollTimeout(fetchReq.LeaseDuration), s.streamCfg.FetchPollInterval, func() (bool, error) {
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
		return connect.NewResponse(&corvov1.FetchResponse{Found: false}), nil
	}

	resp := &corvov1.FetchResponse{
		Found:          true,
		JobId:          result.JobID,
		Queue:          result.Queue,
		PayloadJson:    string(result.Payload),
		Attempt:        int32(result.Attempt),
		MaxRetries:     int32(result.MaxRetries),
		LeaseDuration:  int32(result.LeaseDuration),
		CheckpointJson: string(result.Checkpoint),
		TagsJson:       string(result.Tags),
		Agent:          agentStateToPB(result.Agent),
	}
	return connect.NewResponse(resp), nil
}

func (s *Server) FetchBatch(ctx context.Context, req *connect.Request[corvov1.FetchBatchRequest]) (*connect.Response[corvov1.FetchBatchResponse], error) {
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
	err := waitForFetch(ctx, longPollTimeout(fetchReq.LeaseDuration), s.streamCfg.FetchPollInterval, func() (bool, error) {
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

	respJobs := make([]*corvov1.FetchBatchJob, 0, len(jobs))
	for _, j := range jobs {
		respJobs = append(respJobs, &corvov1.FetchBatchJob{
			JobId:          j.JobID,
			Queue:          j.Queue,
			PayloadJson:    string(j.Payload),
			Attempt:        int32(j.Attempt),
			MaxRetries:     int32(j.MaxRetries),
			LeaseDuration:  int32(j.LeaseDuration),
			CheckpointJson: string(j.Checkpoint),
			TagsJson:       string(j.Tags),
			Agent:          agentStateToPB(j.Agent),
		})
	}
	return connect.NewResponse(&corvov1.FetchBatchResponse{Jobs: respJobs}), nil
}

func (s *Server) Ack(ctx context.Context, req *connect.Request[corvov1.AckRequest]) (*connect.Response[corvov1.AckResponse], error) {
	resultJSON := strings.TrimSpace(req.Msg.GetResultJson())
	if resultJSON == "" {
		resultJSON = `{}`
	}
	if err := s.store.AckJob(store.AckRequest{
		JobID:       req.Msg.GetJobId(),
		Result:      json.RawMessage(resultJSON),
		Checkpoint:  json.RawMessage(strings.TrimSpace(req.Msg.GetCheckpointJson())),
		Usage:       usageFromPB(req.Msg.GetUsage()),
		AgentStatus: req.Msg.GetAgentStatus(),
		HoldReason:  req.Msg.GetHoldReason(),
	}); err != nil {
		return nil, mapStoreError(err)
	}
	return connect.NewResponse(&corvov1.AckResponse{}), nil
}

func (s *Server) AckBatch(ctx context.Context, req *connect.Request[corvov1.AckBatchRequest]) (*connect.Response[corvov1.AckBatchResponse], error) {
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
			Usage:  usageFromPB(item.GetUsage()),
		})
	}

	acked, err := s.store.AckBatch(acks)
	if err != nil {
		return nil, mapStoreError(err)
	}
	return connect.NewResponse(&corvov1.AckBatchResponse{Acked: int32(acked)}), nil
}

func (s *Server) StreamLifecycle(ctx context.Context, stream *connect.BidiStream[corvov1.LifecycleStreamRequest, corvov1.LifecycleStreamResponse]) error {
	// Check leadership before accepting the stream.
	if resp := s.checkLeader(0); resp != nil {
		_ = stream.Send(resp)
		return nil
	}

	s.streamsTotal.Add(1)
	cfg := s.streamCfg
	if n := s.openCount.Add(1); cfg.MaxOpenStreams > 0 && n > int64(cfg.MaxOpenStreams) {
		s.openCount.Add(-1)
		return connect.NewError(connect.CodeResourceExhausted, fmt.Errorf("too many open lifecycle streams"))
	}
	defer s.openCount.Add(-1)

	var minInterval time.Duration
	if cfg.MaxFramesPerSec > 0 {
		minInterval = time.Second / time.Duration(cfg.MaxFramesPerSec)
	}
	var lastFrame time.Time
	var strikes int

	for {
		// Per-stream frame rate limiting.
		if minInterval > 0 && !lastFrame.IsZero() {
			if elapsed := time.Since(lastFrame); elapsed < minInterval {
				time.Sleep(minInterval - elapsed)
			}
		}
		lastFrame = time.Now()

		// Progressive delay when consecutive errors accumulate.
		if strikes > 0 {
			delay := time.Duration(strikes) * cfg.StrikeDelay
			if delay > 500*time.Millisecond {
				delay = 500 * time.Millisecond
			}
			time.Sleep(delay)
		}

		req, err := stream.Receive()
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return connect.NewError(connect.CodeUnknown, fmt.Errorf("stream lifecycle receive: %w", err))
		}

		// Check leadership on every frame; if lost, notify client.
		if resp := s.checkLeader(req.GetRequestId()); resp != nil {
			_ = stream.Send(resp)
			return nil
		}

		resp := &corvov1.LifecycleStreamResponse{
			RequestId: req.GetRequestId(),
		}
		frameHadError := false
		acquired := false
		idleFetchSleep := false
		needWork := len(req.GetAcks()) > 0 || int(req.GetFetchCount()) > 0 || len(req.GetEnqueues()) > 0
		if needWork {
			if cfg.AcquireTimeout <= 0 {
				select {
				case s.frameSem <- struct{}{}:
					acquired = true
				case <-ctx.Done():
					return nil
				}
			} else {
				acquireTimer := time.NewTimer(cfg.AcquireTimeout)
				select {
				case s.frameSem <- struct{}{}:
					acquired = true
				case <-ctx.Done():
					acquireTimer.Stop()
					return nil
				case <-acquireTimer.C:
					frameHadError = true
					resp.Error = "OVERLOADED: lifecycle stream saturated"
					s.overloadTotal.Add(1)
				}
				if !acquireTimer.Stop() {
					select {
					case <-acquireTimer.C:
					default:
					}
				}
			}
		}

		// Parse ack items (cheap, no I/O).
		var acks []store.AckOp
		if acquired && len(req.GetAcks()) > 0 {
			acks = make([]store.AckOp, 0, len(req.GetAcks()))
			for _, item := range req.GetAcks() {
				jobID := strings.TrimSpace(item.GetJobId())
				if jobID == "" {
					if resp.Error == "" {
						resp.Error = "ack: job_id is required"
						frameHadError = true
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
					Usage:  usageFromPB(item.GetUsage()),
				})
			}
		}

		fetchCount := 0
		if acquired {
			fetchCount = int(req.GetFetchCount())
		}

		// Fire ack and fetch into the Raft pipeline concurrently.
		// Both land in the same applyLoop batch window and get merged
		// into a single Raft entry via applyMultiIndexed (which sorts
		// acks before fetches, so freed concurrency slots are visible
		// to the fetch).
		if acquired && (len(acks) > 0 || fetchCount > 0) {
			var wg sync.WaitGroup
			var ackErr error
			var acked int
			var fetchErr error
			var jobs []store.FetchResult

			if len(acks) > 0 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					acked, ackErr = s.store.AckBatch(acks)
				}()
			}

			if fetchCount > 0 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					fetchReq := store.FetchRequest{
						Queues:        req.GetQueues(),
						WorkerID:      req.GetWorkerId(),
						Hostname:      req.GetHostname(),
						LeaseDuration: int(req.GetLeaseDuration()),
					}
					jobs, fetchErr = s.store.FetchBatch(fetchReq, fetchCount)
				}()
			}

			wg.Wait()

			// Collect ack result.
			if ackErr != nil {
				frameHadError = true
				if resp.Error == "" {
					if store.IsOverloadedError(ackErr) {
						resp.Error = "OVERLOADED: ack: " + ackErr.Error()
					} else {
						resp.Error = "ack: " + ackErr.Error()
					}
				}
			} else if len(acks) > 0 {
				resp.Acked = int32(acked)
			}

			// Collect fetch result.
			if fetchErr != nil {
				frameHadError = true
				if resp.Error == "" {
					if store.IsOverloadedError(fetchErr) {
						resp.Error = "OVERLOADED: fetch: " + fetchErr.Error()
					} else {
						resp.Error = "fetch: " + fetchErr.Error()
					}
				}
			} else if fetchCount > 0 {
				respJobs := make([]*corvov1.FetchBatchJob, 0, len(jobs))
				for _, j := range jobs {
					respJobs = append(respJobs, &corvov1.FetchBatchJob{
						JobId:          j.JobID,
						Queue:          j.Queue,
						PayloadJson:    string(j.Payload),
						Attempt:        int32(j.Attempt),
						MaxRetries:     int32(j.MaxRetries),
						LeaseDuration:  int32(j.LeaseDuration),
						CheckpointJson: string(j.Checkpoint),
						TagsJson:       string(j.Tags),
						Agent:          agentStateToPB(j.Agent),
					})
				}
				resp.Jobs = respJobs
				if len(respJobs) == 0 {
					idleFetchSleep = true
				}
			}
		}

		if acquired && len(req.GetEnqueues()) > 0 {
			jobs := make([]store.EnqueueRequest, 0, len(req.GetEnqueues()))
			for _, item := range req.GetEnqueues() {
				queue := strings.TrimSpace(item.GetQueue())
				if queue == "" {
					if resp.Error == "" {
						resp.Error = "enqueue: queue is required"
						frameHadError = true
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
					Agent:   agentConfigFromPB(item.GetAgent()),
				})
			}
			if len(jobs) > 0 {
				enq, err := s.store.EnqueueBatch(store.BatchEnqueueRequest{Jobs: jobs})
				if err != nil {
					frameHadError = true
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
		if acquired {
			<-s.frameSem
			s.framesTotal.Add(1)
		}
		// If fetch was empty AND no other work was done (no acks, no enqueues),
		// sleep outside semaphore to prevent idle busy-looping. Skip the sleep
		// when acks or enqueues were processed so their responses aren't delayed.
		didWork := resp.Acked > 0 || len(resp.EnqueuedJobIds) > 0
		if idleFetchSleep && !didWork {
			s.idleFetchTotal.Add(1)
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(cfg.IdleFetchSleep):
			}
		}

		// Strike tracking: consecutive hard errors trigger progressive delay.
		// Overload is treated as transient and should not close the stream.
		if frameHadError {
			if strings.HasPrefix(resp.Error, "OVERLOADED:") {
				strikes = 0
			} else {
				strikes++
			}
		} else {
			strikes = 0
		}

		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

func (s *Server) Fail(ctx context.Context, req *connect.Request[corvov1.FailRequest]) (*connect.Response[corvov1.FailResponse], error) {
	result, err := s.store.Fail(req.Msg.GetJobId(), req.Msg.GetError(), req.Msg.GetBacktrace(), false)
	if err != nil {
		return nil, mapStoreError(err)
	}

	resp := &corvov1.FailResponse{
		Status:            result.Status,
		AttemptsRemaining: int32(result.AttemptsRemaining),
	}
	if result.NextAttemptAt != nil {
		resp.NextAttemptAt = timestamppb.New(*result.NextAttemptAt)
	}
	return connect.NewResponse(resp), nil
}

func (s *Server) Heartbeat(ctx context.Context, req *connect.Request[corvov1.HeartbeatRequest]) (*connect.Response[corvov1.HeartbeatResponse], error) {
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
		jobUpdate.Usage = usageFromPB(update.GetUsage())
		hbReq.Jobs[jobID] = jobUpdate
	}

	result, err := s.store.Heartbeat(hbReq)
	if err != nil {
		if store.IsOverloadedError(err) {
			return nil, connect.NewError(connect.CodeResourceExhausted, err)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	resp := &corvov1.HeartbeatResponse{Jobs: map[string]*corvov1.HeartbeatJobResponse{}}
	for jobID, status := range result.Jobs {
		resp.Jobs[jobID] = &corvov1.HeartbeatJobResponse{Status: status.Status}
	}
	return connect.NewResponse(resp), nil
}

// ServerInfoHandler returns a plain HTTP handler for the server info endpoint.
func (s *Server) ServerInfoHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		resp, _ := json.Marshal(map[string]string{
			"server_version": s.version,
			"api_version":    s.version,
		})
		_, _ = w.Write(resp)
	}
}

type sdkHeaderLogger struct{}

func sdkHeaderInterceptor() *sdkHeaderLogger { return &sdkHeaderLogger{} }

func logSDKHeaders(headers http.Header, procedure string) {
	clientName := headers.Get("X-Corvo-Client-Name")
	clientVersion := headers.Get("X-Corvo-Client-Version")
	if clientName != "" || clientVersion != "" {
		slog.Debug("sdk client request",
			"client_name", clientName,
			"client_version", clientVersion,
			"procedure", procedure,
		)
	}
}

func (i *sdkHeaderLogger) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		logSDKHeaders(req.Header(), req.Spec().Procedure)
		return next(ctx, req)
	}
}

func (i *sdkHeaderLogger) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (i *sdkHeaderLogger) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		logSDKHeaders(conn.RequestHeader(), conn.Spec().Procedure)
		return next(ctx, conn)
	}
}

func usageFromPB(in *corvov1.UsageReport) *store.UsageReport {
	if in == nil {
		return nil
	}
	return &store.UsageReport{
		InputTokens:         in.GetInputTokens(),
		OutputTokens:        in.GetOutputTokens(),
		CacheCreationTokens: in.GetCacheCreationTokens(),
		CacheReadTokens:     in.GetCacheReadTokens(),
		Model:               strings.TrimSpace(in.GetModel()),
		Provider:            strings.TrimSpace(in.GetProvider()),
		CostUSD:             in.GetCostUsd(),
	}
}

func agentConfigFromPB(in *corvov1.AgentConfig) *store.AgentConfig {
	if in == nil {
		return nil
	}
	return &store.AgentConfig{
		MaxIterations:    int(in.GetMaxIterations()),
		MaxCostUSD:       in.GetMaxCostUsd(),
		IterationTimeout: strings.TrimSpace(in.GetIterationTimeout()),
	}
}

func agentStateToPB(in *store.AgentState) *corvov1.AgentState {
	if in == nil {
		return nil
	}
	return &corvov1.AgentState{
		MaxIterations:    int32(in.MaxIterations),
		MaxCostUsd:       in.MaxCostUSD,
		IterationTimeout: in.IterationTimeout,
		Iteration:        int32(in.Iteration),
		TotalCostUsd:     in.TotalCostUSD,
	}
}
