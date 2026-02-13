# jobbie-client

Python client for Jobbie's HTTP API.

## Quick start

```python
from jobbie_client import JobbieClient

client = JobbieClient("http://localhost:8080")
enq = client.enqueue("emails.send", {"to": "user@example.com"})
client.ack(enq["job_id"], {"result": {"ok": True}})
```

## Auth

```python
client = JobbieClient(
    "http://localhost:8080",
    api_key="your-api-key",
    bearer_token="your-jwt",
    headers={"x-tenant": "acme"},
)
```

For worker runtime support, use `jobbie-worker`.
