# @corvo/client

TypeScript client for Corvo's HTTP API.

## Quick start

```ts
import { CorvoClient } from "@corvo/client";

const client = new CorvoClient("http://localhost:8080");
const enq = await client.enqueue("emails.send", { to: "user@example.com" });
await client.ack(enq.job_id, { result: { ok: true } });
```

## Auth

```ts
const client = new CorvoClient("http://localhost:8080", fetch, {
  apiKey: process.env.CORVO_API_KEY || "",
  bearerToken: process.env.CORVO_BEARER || "",
  headers: { "x-tenant": "acme" },
});
```

For worker runtime support, use `@corvo/worker`.
