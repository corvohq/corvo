# jobbie-client

Python client for Jobbie's HTTP API.

## Quick start

```python
from jobbie_client import JobbieClient

client = JobbieClient("http://localhost:8080")
enq = client.enqueue("emails.send", {"to": "user@example.com"})
client.ack(enq["job_id"], {"result": {"ok": True}})
```
