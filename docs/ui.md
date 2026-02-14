# Corvo UI — Feature Roadmap

The admin UI is a React 19 SPA (Vite, Radix/shadcn, Tailwind CSS v4) embedded in the Go binary via `embed.FS`. Real-time updates via SSE. Served at `/ui/`.

## Implemented

- Dashboard with summary stats, queue table, recent failures, workers, cluster panel
- Queue detail with search/filter, job table, bulk actions, queue actions (pause/resume/drain/clear/concurrency/throttle)
- Job detail with payload viewer, timeline, error history, retry/cancel/move/delete
- Top-level queues page with nav link
- Dead letter and held jobs views
- Cost dashboard (AI agent cost/budget/iteration tracking)
- Workers page
- Cluster page
- SSE-driven cache invalidation with exponential backoff reconnect (3s-30s)
- Mobile-responsive sidebar (Sheet drawer on small screens)
- Dark mode toggle with localStorage persistence and system preference fallback
- Enqueue job dialog (queue, JSON payload, priority, max retries, scheduled at, unique key)
- Date range filters in search panel (created after/before)
- Bulk operation progress indicator (indeterminate bar + spinner during pending)
- Static asset cache headers (immutable for hashed assets, no-cache for index.html)
- Extracted concurrency/throttle dialogs as standalone components

## Parity — features most mature dashboards have

These are table-stakes features found in Sidekiq, Bull Board, Asynqmon, etc.

### Throughput and latency graphs
Time-series charts showing processed/failed jobs per minute and p50/p95 execution time per job type. Sidekiq 7.0's Metrics tab shows the last hour with 1-minute granularity. recharts is already in deps and SSE provides the real-time data feed — this is mostly a matter of adding a metrics aggregation endpoint on the backend and a chart component on the frontend.

### Queue latency
How long the oldest pending job in each queue has been waiting. A single number per queue, displayed prominently on the dashboard and queue table. Sidekiq shows this on its main page.

### Error stack trace viewer
Expandable, syntax-highlighted backtrace display in job detail. Currently errors are shown but could be improved with collapsible frames, line highlighting, and copy-to-clipboard.

### Retry with payload edit
Let admins edit the payload JSON before retrying a failed job, not just blind retry. Useful when a job failed due to bad input data.

### Scheduled jobs view
Dedicated page for jobs with `scheduled_at` in the future. Show countdown to execution, with ability to promote (run now) or cancel. Currently these are findable via search but deserve their own nav item.

### Stale worker detection
Flag workers whose last heartbeat is older than a configurable threshold (e.g. 60s). Show a warning badge, offer cleanup/deregister action. Currently the workers table shows heartbeat time but doesn't flag staleness.

### Shareable URL state
Persist search filters, pagination cursor, and active tab to the URL query string so links can be shared (e.g. "page 3 of dead letter jobs in queue X").

## Differentiators — features that would set Corvo apart

### Live event stream
Expose the existing SSE feed as a visible real-time event log in the UI (like `kubectl logs -f` or Temporal's event history). Show job state transitions, enqueues, failures, and retries as they happen with auto-scroll and pause. Very few job dashboards surface their event stream to users.

### AI agent observability
Lean into the AI agent story — this is unique to Corvo's domain. Per-job token usage, model calls, cost overlaid on the job timeline. Iteration traces showing each agent loop step with input/output/score. Budget burn-down charts per queue. No other job dashboard has this because they don't run AI workloads. (Partially implemented via cost dashboard, iteration table, budget bar, score summary, held card components.)

### Diff view for retries
When a job is retried (especially with payload edit), show a diff of what changed between attempts — payload edits, different errors, different duration. Makes debugging flaky jobs much faster.

### Queue health scoring
A computed health score per queue based on error rate, latency, throughput trend. Red/yellow/green indicators that are more immediately actionable than raw numbers. Could use a simple formula: `health = f(error_rate, p95_latency, queue_depth_trend)`.

### Keyboard shortcuts
Power-user navigation: `j/k` to move between jobs, `/` to focus search, `r` to retry, `d` to delete, `Esc` to close dialogs. Job dashboards almost never have keyboard navigation.

### Webhook/alert configuration from UI
Let admins configure alerts directly from the dashboard: "notify me when dead letter count > N" or "queue latency > 30s". Currently this would require config files or external monitoring.

### Job replay/clone
Take any completed or failed job and re-enqueue it with the same payload to a queue. Different from retry (which only works on failed jobs and keeps the same job ID).

### Compare time ranges
"Show me error rate this hour vs. same hour yesterday." Useful for correlating issues with deploys. Similar to Sidekiq's deploy markers feature but more flexible.

### Export search results
CSV/JSON export of current search results. Surprisingly uncommon in job dashboards. Useful for incident investigation and sharing with teammates.

### Job dependency visualization
If jobs have parent/child or batch relationships, render them as a graph/DAG. Temporal does this for workflows; almost no simple job queue does it.
