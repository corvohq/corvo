# corvo-client

Python client for Corvo's HTTP API.

## Quick start

```python
from corvo_client import CorvoClient

client = CorvoClient("http://localhost:8080")
enq = client.enqueue("emails.send", {"to": "user@example.com"})
client.ack(enq["job_id"], {"result": {"ok": True}})
```

## Auth

```python
client = CorvoClient(
    "http://localhost:8080",
    api_key="your-api-key",
    bearer_token="your-jwt",
    headers={"x-tenant": "acme"},
)
```

For worker runtime support, use `corvo-worker`.
