# @corvo/worker

TypeScript worker runtime for Corvo.

Depends on `@corvo/client` and provides:
- queue handler registration
- fetch/ack/fail loop
- heartbeat and cancellation signals
- graceful shutdown/drain

## Quick start

```ts
import { CorvoClient } from "@corvo/client";
import { CorvoWorker } from "@corvo/worker";

const client = new CorvoClient("http://localhost:8080", fetch, {
  apiKey: process.env.CORVO_API_KEY || "",
});
const worker = new CorvoWorker(client, {
  queues: ["emails.send"],
  workerID: "worker-ts-1",
  concurrency: 8,
});

worker.register("emails.send", async (job, ctx) => {
  if (ctx.isCancelled()) return;
  await ctx.progress(1, 1, "sending");
  // handle job.payload
});

await worker.start();
```
