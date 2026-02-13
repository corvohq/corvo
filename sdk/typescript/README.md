# @jobbie/client

TypeScript client for Jobbie's HTTP API.

## Quick start

```ts
import { JobbieClient } from "@jobbie/client";

const client = new JobbieClient("http://localhost:8080");
const enq = await client.enqueue("emails.send", { to: "user@example.com" });
await client.ack(enq.job_id, { result: { ok: true } });
```

## Auth

```ts
const client = new JobbieClient("http://localhost:8080", fetch, {
  apiKey: process.env.JOBBIE_API_KEY || "",
  bearerToken: process.env.JOBBIE_BEARER || "",
  headers: { "x-tenant": "acme" },
});
```

For worker runtime support, use `@jobbie/worker`.
