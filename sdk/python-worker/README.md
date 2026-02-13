# jobbie-worker

Python worker runtime for Jobbie.

Depends on `jobbie-client` and provides:
- queue handler registration
- fetch/ack/fail loop
- heartbeat and cancellation signals
- graceful shutdown/drain

## Quick start

```python
from jobbie_client import JobbieClient
from jobbie_worker import JobbieWorker, WorkerConfig

client = JobbieClient("http://localhost:8080", api_key="your-api-key")
worker = JobbieWorker(
    client,
    WorkerConfig(
        queues=["emails.send"],
        worker_id="worker-py-1",
        concurrency=8,
    ),
)

def handle_email(job, ctx):
    if ctx.is_cancelled():
        return
    ctx.progress(1, 1, "sending")

worker.register("emails.send", handle_email)
worker.start()
```
