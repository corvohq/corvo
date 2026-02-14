package worker

import "github.com/user/corvo/pkg/client"

// Worker runtime aliases that make lifecycle-oriented imports explicit.
// This package is intentionally thin and delegates behavior to pkg/client.
type (
	FetchedJob   = client.FetchedJob
	JobContext   = client.JobContext
	Handler      = client.Handler
	Worker       = client.Worker
	WorkerConfig = client.WorkerConfig
)

func New(cfg WorkerConfig) *Worker {
	return client.NewWorker(cfg)
}
