# @jobbie/worker

TypeScript worker runtime for Jobbie.

Depends on `@jobbie/client` and provides:
- queue handler registration
- fetch/ack/fail loop
- heartbeat and cancellation signals
- graceful shutdown/drain

## Quick start

```ts
import { JobbieClient } from "@jobbie/client";
import { JobbieWorker } from "@jobbie/worker";

const client = new JobbieClient("http://localhost:8080", fetch, {
  apiKey: process.env.JOBBIE_API_KEY || "",
});
const worker = new JobbieWorker(client, {
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
