package workerclient

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"
	jobbiev1 "github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1"
	"github.com/user/jobbie/internal/rpcconnect/gen/jobbie/v1/jobbiev1connect"
	"golang.org/x/net/http2"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Client is a typed worker lifecycle client over Connect RPC.
type Client struct {
	rpc jobbiev1connect.WorkerServiceClient
}

// Option configures a Client.
type Option func(*config)

type config struct {
	httpClient *http.Client
	useJSON    bool
}

// WithHTTPClient overrides the HTTP client used by Connect.
func WithHTTPClient(c *http.Client) Option {
	return func(cfg *config) {
		if c != nil {
			cfg.httpClient = c
		}
	}
}

// WithProtoJSON forces JSON payload encoding for requests/responses.
func WithProtoJSON() Option {
	return func(cfg *config) { cfg.useJSON = true }
}

// New creates a worker client for a Jobbie server base URL.
func New(baseURL string, opts ...Option) *Client {
	cfg := config{
		httpClient: defaultHTTPClient(),
	}
	for _, opt := range opts {
		opt(&cfg)
	}

	var clientOpts []connect.ClientOption
	if cfg.useJSON {
		clientOpts = append(clientOpts, connect.WithProtoJSON())
	}

	rpc := jobbiev1connect.NewWorkerServiceClient(cfg.httpClient, strings.TrimRight(baseURL, "/"), clientOpts...)
	return &Client{rpc: rpc}
}

func defaultHTTPClient() *http.Client {
	dialer := &net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	tr := &http2.Transport{
		AllowHTTP: true,
		DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
			return dialer.DialContext(ctx, network, addr)
		},
		ReadIdleTimeout: 30 * time.Second,
		PingTimeout:     10 * time.Second,
	}
	return &http.Client{
		// Streaming lifecycle RPCs are long-lived; rely on per-request contexts
		// instead of a global client timeout that can terminate active streams.
		Timeout:   0,
		Transport: tr,
	}
}

type EnqueueRequest struct {
	Queue   string
	Payload json.RawMessage
}

type EnqueueResponse struct {
	JobID          string
	Status         string
	UniqueExisting bool
}

func (c *Client) Enqueue(ctx context.Context, req EnqueueRequest) (*EnqueueResponse, error) {
	if req.Queue == "" {
		return nil, fmt.Errorf("queue is required")
	}
	payload := strings.TrimSpace(string(req.Payload))
	if payload == "" {
		payload = `{}`
	}

	resp, err := c.rpc.Enqueue(ctx, connect.NewRequest(&jobbiev1.EnqueueRequest{
		Queue:       req.Queue,
		PayloadJson: payload,
	}))
	if err != nil {
		return nil, err
	}
	return &EnqueueResponse{
		JobID:          resp.Msg.GetJobId(),
		Status:         resp.Msg.GetStatus(),
		UniqueExisting: resp.Msg.GetUniqueExisting(),
	}, nil
}

type FetchRequest struct {
	Queues        []string
	WorkerID      string
	Hostname      string
	LeaseDuration int
}

type FetchedJob struct {
	JobID         string
	Queue         string
	Payload       json.RawMessage
	Attempt       int
	MaxRetries    int
	LeaseDuration int
	Checkpoint    json.RawMessage
	Tags          json.RawMessage
}

// Fetch returns nil,nil when no job is available.
func (c *Client) Fetch(ctx context.Context, req FetchRequest) (*FetchedJob, error) {
	resp, err := c.rpc.Fetch(ctx, connect.NewRequest(&jobbiev1.FetchRequest{
		Queues:        req.Queues,
		WorkerId:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: int32(req.LeaseDuration),
	}))
	if err != nil {
		return nil, err
	}
	if !resp.Msg.GetFound() {
		return nil, nil
	}
	return &FetchedJob{
		JobID:         resp.Msg.GetJobId(),
		Queue:         resp.Msg.GetQueue(),
		Payload:       json.RawMessage(resp.Msg.GetPayloadJson()),
		Attempt:       int(resp.Msg.GetAttempt()),
		MaxRetries:    int(resp.Msg.GetMaxRetries()),
		LeaseDuration: int(resp.Msg.GetLeaseDuration()),
		Checkpoint:    json.RawMessage(resp.Msg.GetCheckpointJson()),
		Tags:          json.RawMessage(resp.Msg.GetTagsJson()),
	}, nil
}

func (c *Client) FetchBatch(ctx context.Context, req FetchRequest, count int) ([]FetchedJob, error) {
	if count <= 0 {
		count = 1
	}
	resp, err := c.rpc.FetchBatch(ctx, connect.NewRequest(&jobbiev1.FetchBatchRequest{
		Queues:        req.Queues,
		WorkerId:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: int32(req.LeaseDuration),
		Count:         int32(count),
	}))
	if err != nil {
		return nil, err
	}
	jobs := make([]FetchedJob, 0, len(resp.Msg.GetJobs()))
	for _, j := range resp.Msg.GetJobs() {
		jobs = append(jobs, FetchedJob{
			JobID:         j.GetJobId(),
			Queue:         j.GetQueue(),
			Payload:       json.RawMessage(j.GetPayloadJson()),
			Attempt:       int(j.GetAttempt()),
			MaxRetries:    int(j.GetMaxRetries()),
			LeaseDuration: int(j.GetLeaseDuration()),
			Checkpoint:    json.RawMessage(j.GetCheckpointJson()),
			Tags:          json.RawMessage(j.GetTagsJson()),
		})
	}
	return jobs, nil
}

func (c *Client) Ack(ctx context.Context, jobID string, result json.RawMessage) error {
	return c.AckWithUsage(ctx, jobID, result, nil)
}

func (c *Client) AckWithUsage(ctx context.Context, jobID string, result json.RawMessage, usage *UsageReport) error {
	if jobID == "" {
		return fmt.Errorf("job_id is required")
	}
	resultJSON := strings.TrimSpace(string(result))
	if resultJSON == "" {
		resultJSON = `{}`
	}
	_, err := c.rpc.Ack(ctx, connect.NewRequest(&jobbiev1.AckRequest{
		JobId:      jobID,
		ResultJson: resultJSON,
		Usage:      usageToPB(usage),
	}))
	return err
}

type AckBatchItem struct {
	JobID  string
	Result json.RawMessage
	Usage  *UsageReport
}

func (c *Client) AckBatch(ctx context.Context, items []AckBatchItem) (int, error) {
	if len(items) == 0 {
		return 0, fmt.Errorf("items is required")
	}
	reqItems := make([]*jobbiev1.AckBatchItem, 0, len(items))
	for _, item := range items {
		jobID := strings.TrimSpace(item.JobID)
		if jobID == "" {
			return 0, fmt.Errorf("job_id is required")
		}
		resultJSON := strings.TrimSpace(string(item.Result))
		if resultJSON == "" {
			resultJSON = `{}`
		}
		reqItems = append(reqItems, &jobbiev1.AckBatchItem{
			JobId:      jobID,
			ResultJson: resultJSON,
			Usage:      usageToPB(item.Usage),
		})
	}

	resp, err := c.rpc.AckBatch(ctx, connect.NewRequest(&jobbiev1.AckBatchRequest{Items: reqItems}))
	if err != nil {
		return 0, err
	}
	return int(resp.Msg.GetAcked()), nil
}

type LifecycleRequest struct {
	RequestID    uint64
	Queues       []string
	WorkerID     string
	Hostname     string
	LeaseSeconds int
	FetchCount   int
	Acks         []AckBatchItem
	Enqueues     []LifecycleEnqueueItem
}

type LifecycleEnqueueItem struct {
	Queue   string
	Payload json.RawMessage
}

type LifecycleResponse struct {
	RequestID      uint64
	Jobs           []FetchedJob
	Acked          int
	EnqueuedJobIDs []string
	Error          string
}

type LifecycleStream struct {
	stream *connect.BidiStreamForClient[jobbiev1.LifecycleStreamRequest, jobbiev1.LifecycleStreamResponse]
	mu     sync.Mutex
	closed bool
}

func (c *Client) OpenLifecycleStream(ctx context.Context) *LifecycleStream {
	return &LifecycleStream{stream: c.rpc.StreamLifecycle(ctx)}
}

func (s *LifecycleStream) Exchange(req LifecycleRequest) (*LifecycleResponse, error) {
	if s == nil || s.stream == nil {
		return nil, fmt.Errorf("lifecycle stream is not open")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, io.EOF
	}

	items := make([]*jobbiev1.AckBatchItem, 0, len(req.Acks))
	for _, ack := range req.Acks {
		jobID := strings.TrimSpace(ack.JobID)
		if jobID == "" {
			return nil, fmt.Errorf("job_id is required")
		}
		resultJSON := strings.TrimSpace(string(ack.Result))
		if resultJSON == "" {
			resultJSON = `{}`
		}
		items = append(items, &jobbiev1.AckBatchItem{
			JobId:      jobID,
			ResultJson: resultJSON,
			Usage:      usageToPB(ack.Usage),
		})
	}
	enqueues := make([]*jobbiev1.LifecycleEnqueueItem, 0, len(req.Enqueues))
	for _, enq := range req.Enqueues {
		queue := strings.TrimSpace(enq.Queue)
		if queue == "" {
			return nil, fmt.Errorf("enqueue queue is required")
		}
		payload := strings.TrimSpace(string(enq.Payload))
		if payload == "" {
			payload = `{}`
		}
		enqueues = append(enqueues, &jobbiev1.LifecycleEnqueueItem{
			Queue:       queue,
			PayloadJson: payload,
		})
	}

	if err := s.stream.Send(&jobbiev1.LifecycleStreamRequest{
		RequestId:     req.RequestID,
		Queues:        req.Queues,
		WorkerId:      req.WorkerID,
		Hostname:      req.Hostname,
		LeaseDuration: int32(req.LeaseSeconds),
		FetchCount:    int32(req.FetchCount),
		Acks:          items,
		Enqueues:      enqueues,
	}); err != nil {
		return nil, err
	}

	msg, err := s.stream.Receive()
	if err != nil {
		if err == io.EOF {
			return nil, io.EOF
		}
		return nil, err
	}
	resp := &LifecycleResponse{
		RequestID: msg.GetRequestId(),
		Acked:     int(msg.GetAcked()),
		Error:     msg.GetError(),
	}
	resp.EnqueuedJobIDs = append(resp.EnqueuedJobIDs, msg.GetEnqueuedJobIds()...)
	resp.Jobs = make([]FetchedJob, 0, len(msg.GetJobs()))
	for _, j := range msg.GetJobs() {
		resp.Jobs = append(resp.Jobs, FetchedJob{
			JobID:         j.GetJobId(),
			Queue:         j.GetQueue(),
			Payload:       json.RawMessage(j.GetPayloadJson()),
			Attempt:       int(j.GetAttempt()),
			MaxRetries:    int(j.GetMaxRetries()),
			LeaseDuration: int(j.GetLeaseDuration()),
			Checkpoint:    json.RawMessage(j.GetCheckpointJson()),
			Tags:          json.RawMessage(j.GetTagsJson()),
		})
	}
	return resp, nil
}

func (s *LifecycleStream) Close() error {
	if s == nil || s.stream == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	return s.stream.CloseRequest()
}

type FailResponse struct {
	Status            string
	NextAttemptAt     *time.Time
	AttemptsRemaining int
}

func (c *Client) Fail(ctx context.Context, jobID, errMsg, backtrace string) (*FailResponse, error) {
	if jobID == "" {
		return nil, fmt.Errorf("job_id is required")
	}
	resp, err := c.rpc.Fail(ctx, connect.NewRequest(&jobbiev1.FailRequest{
		JobId:     jobID,
		Error:     errMsg,
		Backtrace: backtrace,
	}))
	if err != nil {
		return nil, err
	}

	return &FailResponse{
		Status:            resp.Msg.GetStatus(),
		NextAttemptAt:     fromProtoTime(resp.Msg.GetNextAttemptAt()),
		AttemptsRemaining: int(resp.Msg.GetAttemptsRemaining()),
	}, nil
}

type HeartbeatJobUpdate struct {
	Progress   map[string]any
	Checkpoint map[string]any
	Usage      *UsageReport
}

// Heartbeat returns per-job status (e.g. "ok", "cancel").
func (c *Client) Heartbeat(ctx context.Context, jobs map[string]HeartbeatJobUpdate) (map[string]string, error) {
	reqJobs := make(map[string]*jobbiev1.HeartbeatJobUpdate, len(jobs))
	for jobID, update := range jobs {
		progressJSON, err := marshalMap(update.Progress)
		if err != nil {
			return nil, fmt.Errorf("marshal progress for %s: %w", jobID, err)
		}
		checkpointJSON, err := marshalMap(update.Checkpoint)
		if err != nil {
			return nil, fmt.Errorf("marshal checkpoint for %s: %w", jobID, err)
		}
		reqJobs[jobID] = &jobbiev1.HeartbeatJobUpdate{
			ProgressJson:   progressJSON,
			CheckpointJson: checkpointJSON,
			Usage:          usageToPB(update.Usage),
		}
	}

	resp, err := c.rpc.Heartbeat(ctx, connect.NewRequest(&jobbiev1.HeartbeatRequest{Jobs: reqJobs}))
	if err != nil {
		return nil, err
	}

	result := make(map[string]string, len(resp.Msg.GetJobs()))
	for jobID, r := range resp.Msg.GetJobs() {
		result[jobID] = r.GetStatus()
	}
	return result, nil
}

func marshalMap(m map[string]any) (string, error) {
	if m == nil {
		return "", nil
	}
	b, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func fromProtoTime(ts *timestamppb.Timestamp) *time.Time {
	if ts == nil {
		return nil
	}
	t := ts.AsTime()
	return &t
}

type UsageReport struct {
	InputTokens         int64
	OutputTokens        int64
	CacheCreationTokens int64
	CacheReadTokens     int64
	Model               string
	Provider            string
	CostUSD             float64
}

func usageToPB(u *UsageReport) *jobbiev1.UsageReport {
	if u == nil {
		return nil
	}
	return &jobbiev1.UsageReport{
		InputTokens:         u.InputTokens,
		OutputTokens:        u.OutputTokens,
		CacheCreationTokens: u.CacheCreationTokens,
		CacheReadTokens:     u.CacheReadTokens,
		Model:               strings.TrimSpace(u.Model),
		Provider:            strings.TrimSpace(u.Provider),
		CostUsd:             u.CostUSD,
	}
}
