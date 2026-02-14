# Corvo AI

First-class support for AI/LLM workloads. Everything in this document is additive to the core design in [DESIGN.md](./DESIGN.md) — no breaking changes to existing APIs, schema, or behavior.

## Why

LLM API calls are the perfect job queue use case: they're slow (seconds, not milliseconds), expensive ($0.01–$1+ per call), flaky (429s, 503s, rate limits), and non-deterministic (same input, different output). Every team building on LLMs ends up reinventing job queue primitives inside their agent framework — retries, rate limiting, cost tracking, timeouts, human approval gates.

Corvo already handles most of this. This document describes the features that make it *purpose-built* for AI workloads.

---

## Token and cost tracking

Workers report LLM usage alongside job results. The server aggregates this for dashboards, budgets, and cost analysis.

### Reporting usage on ack

The existing `POST /api/v1/ack/{job_id}` endpoint accepts a new optional `usage` field:

```
POST /api/v1/ack/{job_id}
Content-Type: application/json

{
  "result": { "summary": "Acme Corp is a..." },
  "usage": {
    "input_tokens": 1523,
    "output_tokens": 847,
    "model": "claude-sonnet-4-5-20250929",
    "provider": "anthropic",
    "cost_usd": 0.0134,
    "latency_ms": 1823
  }
}
```

Workers can also report usage incrementally via heartbeat, useful for agent loops where a single job makes multiple LLM calls:

```
POST /api/v1/heartbeat
Content-Type: application/json

{
  "jobs": {
    "job_01HX...": {
      "progress": { "current": 3, "total": 10, "message": "Iteration 3" },
      "usage": {
        "input_tokens": 4200,
        "output_tokens": 1100,
        "model": "claude-sonnet-4-5-20250929",
        "cost_usd": 0.031
      }
    }
  }
}
```

Usage reported via heartbeat is cumulative for the current attempt. The server stores per-attempt usage and computes totals.

### Schema

```sql
CREATE TABLE job_usage (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    attempt    INTEGER NOT NULL,
    model      TEXT,
    provider   TEXT,
    input_tokens   INTEGER NOT NULL DEFAULT 0,
    output_tokens  INTEGER NOT NULL DEFAULT 0,
    cost_usd       REAL NOT NULL DEFAULT 0,
    latency_ms     INTEGER,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_job_usage_job ON job_usage(job_id);
CREATE INDEX idx_job_usage_provider ON job_usage(provider, created_at);
CREATE INDEX idx_job_usage_model ON job_usage(model, created_at);
```

### Usage query endpoints

```
GET /api/v1/usage/summary?period=24h                    — total tokens + cost
GET /api/v1/usage/summary?period=7d&group_by=queue      — cost per queue
GET /api/v1/usage/summary?period=7d&group_by=model      — cost per model
GET /api/v1/usage/summary?period=30d&group_by=tag:tenant — cost per tenant
```

**Response:**
```json
{
  "period": "7d",
  "groups": [
    {
      "key": "agents.research",
      "input_tokens": 2340000,
      "output_tokens": 891000,
      "cost_usd": 47.23,
      "jobs_completed": 1204,
      "cost_per_job_usd": 0.039
    },
    {
      "key": "extraction.invoices",
      "input_tokens": 890000,
      "output_tokens": 120000,
      "cost_usd": 12.10,
      "jobs_completed": 4521,
      "cost_per_job_usd": 0.003
    }
  ],
  "totals": {
    "input_tokens": 3230000,
    "output_tokens": 1011000,
    "cost_usd": 59.33,
    "jobs_completed": 5725
  }
}
```

---

## Budget enforcement

Hard spending limits that the server enforces. Prevents runaway agents and surprise bills.

### Configuration

Budgets are set per-queue, per-tag, or globally:

```
POST /api/v1/budgets
Content-Type: application/json

{
  "scope": "queue",
  "target": "agents.research",
  "limits": {
    "daily_usd": 50.00,
    "per_job_usd": 2.00
  },
  "on_exceed": "hold"
}
```

**`on_exceed` actions:**
- `hold` — new jobs enter `held` state, require manual approval to proceed
- `reject` — enqueue returns 429 with a budget error
- `alert_only` — emit event + metric, don't block

### Server-side enforcement

On each `POST /api/v1/fetch`, the server checks:

1. Has the queue's daily budget been exceeded? (sum `job_usage.cost_usd` for today)
2. Before returning a job, does the job's estimated cost (based on queue average) approach the per-job limit?

On each usage report (ack or heartbeat), the server checks:

3. Has the running job exceeded its per-job budget? If so, include a `budget_exceeded: true` signal in the next heartbeat response. The worker should wrap up and ack/fail.

### Schema

```sql
CREATE TABLE budgets (
    id         TEXT PRIMARY KEY,
    scope      TEXT NOT NULL,                -- 'queue', 'tag', 'global'
    target     TEXT NOT NULL,                -- queue name, 'tenant:acme', '*'
    daily_usd  REAL,
    per_job_usd REAL,
    on_exceed  TEXT NOT NULL DEFAULT 'hold', -- 'hold', 'reject', 'alert_only'
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE UNIQUE INDEX idx_budgets_scope ON budgets(scope, target);
```

---

## Agent loop primitive

An agent is a loop: call LLM, get tool calls, execute tools, feed results back, repeat until done. Corvo models this as an iterative job — each iteration is a discrete unit of work with its own audit trail, and the server enforces guardrails.

This is not workflow orchestration. There are no DAGs, no step definitions, no state machines to author. It's a single job that keeps re-executing until it declares itself done.

### Enqueue an agent job

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "agents.research",
  "payload": {
    "goal": "Find the top 3 competitors to Acme Corp and summarize their products",
    "messages": []
  },
  "agent": {
    "max_iterations": 20,
    "max_cost_usd": 1.00,
    "iteration_timeout": "2m"
  },
  "tags": { "tenant": "acme-corp" }
}
```

The `agent` field is optional. When present, the server treats the job as an iterative agent with server-enforced limits.

### Worker protocol

The worker fetches the job like any other. The fetch response includes agent metadata:

```json
{
  "job_id": "job_01HX...",
  "queue": "agents.research",
  "payload": { "goal": "...", "messages": [...] },
  "agent": {
    "iteration": 3,
    "max_iterations": 20,
    "total_cost_usd": 0.42,
    "max_cost_usd": 1.00
  },
  "checkpoint": { "messages": [...], "tool_results": [...] }
}
```

On completion, the worker returns one of three statuses:

**Continue (more iterations needed):**
```
POST /api/v1/ack/{job_id}
Content-Type: application/json

{
  "agent_status": "continue",
  "checkpoint": {
    "messages": [
      {"role": "user", "content": "Find competitors..."},
      {"role": "assistant", "content": "I'll search for...", "tool_calls": [...]},
      {"role": "tool", "content": "Search results: ..."}
    ]
  },
  "usage": { "input_tokens": 2100, "output_tokens": 340, "model": "claude-sonnet-4-5-20250929", "cost_usd": 0.015 }
}
```

The server:
1. Records the usage for this iteration
2. Increments the iteration counter
3. Checks guardrails (max iterations, max cost)
4. If guardrails pass: re-enqueues the job with updated checkpoint as `pending`
5. If guardrails exceeded: moves to `held` state with reason

**Done (agent finished):**
```json
{
  "agent_status": "done",
  "result": {
    "competitors": ["CompA", "CompB", "CompC"],
    "summary": "..."
  },
  "usage": { "input_tokens": 1800, "output_tokens": 920, "model": "claude-sonnet-4-5-20250929", "cost_usd": 0.018 }
}
```

Normal job completion. Full iteration history preserved.

**Hold (needs human approval):**
```json
{
  "agent_status": "hold",
  "hold_reason": "Agent wants to send email to customer@acme.com",
  "hold_payload": {
    "action": "send_email",
    "to": "customer@acme.com",
    "draft": "Dear Customer, ..."
  },
  "checkpoint": { "messages": [...] },
  "usage": { "input_tokens": 1200, "output_tokens": 400, "model": "claude-sonnet-4-5-20250929", "cost_usd": 0.011 }
}
```

The server moves the job to `held` state. See [Human-in-the-loop](#human-in-the-loop) below.

### What the server enforces

Workers don't need to implement any of these — the server handles it:

| Guardrail | How it works |
|---|---|
| Max iterations | Server counts iterations. On exceed → `held` state with reason. |
| Max cost | Server sums usage across iterations. On exceed → `held` state with reason. |
| Iteration timeout | Each iteration is a normal job with a lease. If the worker dies, the lease expires and the iteration retries. |
| Crash recovery | If a worker dies mid-iteration, the server reclaims the lease. The next fetch picks up the job with its checkpoint intact. |
| Cancellation | Cancel an agent job via API/UI. Worker gets cancel signal on next heartbeat. |

### Iteration tracking

Each iteration is recorded as an entry in the `job_iterations` table:

```sql
CREATE TABLE job_iterations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id      TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    iteration   INTEGER NOT NULL,
    status      TEXT NOT NULL,                -- 'continue', 'done', 'hold', 'failed'
    checkpoint  TEXT,                          -- JSON: accumulated state
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    model       TEXT,
    cost_usd    REAL NOT NULL DEFAULT 0,
    latency_ms  INTEGER,
    started_at  TEXT NOT NULL,
    completed_at TEXT,
    worker_id   TEXT
);
CREATE INDEX idx_job_iterations_job ON job_iterations(job_id, iteration);
```

### Replay

Re-run an agent from a specific iteration with different parameters:

```
POST /api/v1/jobs/{id}/replay
Content-Type: application/json

{
  "from_iteration": 3,
  "overrides": {
    "agent": { "max_iterations": 30 },
    "payload": { "model": "claude-opus-4-6" }
  }
}
```

The server creates a new job with:
- The checkpoint from iteration 3 of the original job
- The original payload merged with overrides
- A `replayed_from` field linking to the original job

CLI shorthand:
```bash
corvo replay job_01HX7Y --from 3 --set agent.max_iterations=30
```

---

## Human-in-the-loop

Jobs can be paused for human review and approval. This works for both agent jobs (mid-loop approval) and regular jobs (pre-execution review).

### The `held` state

A new job state that sits between `pending` and `active`:

```
                  ┌───────────┐
                  │ scheduled │
                  └─────┬─────┘
                        │
                        ▼
┌────────┐       ┌─────────┐      ┌────────┐      ┌────────┐
│producer│──────►│ pending │─────►│ active │─────►│  done  │
└────────┘       └─────────┘      └───┬────┘      └────────┘
                      ▲               │
                      │          ┌────┴────┐
                      │          │  held   │ ◄── agent requests hold
                      │          │         │ ◄── budget exceeded
                      │          │         │ ◄── approval policy triggered
                      │          └────┬────┘
                      │               │
                      │         approve / reject
                      │               │
                      └───────────────┘  (approve → back to pending)
                                         (reject → cancelled)
```

The `held` state does not affect existing jobs. Jobs only enter `held` if:
1. An agent worker returns `agent_status: "hold"`
2. A budget limit is exceeded with `on_exceed: "hold"`
3. An approval policy triggers (see below)
4. A job is explicitly held via API: `POST /api/v1/jobs/{id}/hold`

### Holding a job at enqueue time

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "emails.send",
  "payload": { "to": "ceo@bigclient.com", "draft": "..." },
  "hold": {
    "reason": "Sending to VIP contact — requires approval",
    "timeout": "4h",
    "timeout_action": "cancel"
  }
}
```

The job is created in `held` state. It appears in the UI with the reason and Approve / Reject buttons.

**`timeout_action` options:**
- `cancel` — auto-cancel if no approval within timeout
- `approve` — auto-approve if no rejection within timeout (for low-risk holds)
- `none` — wait indefinitely

### Approval / rejection

```
POST /api/v1/jobs/{id}/approve
Content-Type: application/json

{
  "approved_by": "jeremy",
  "note": "Looks good, send it"
}

→ 200 OK { "status": "pending" }
```

```
POST /api/v1/jobs/{id}/reject
Content-Type: application/json

{
  "rejected_by": "jeremy",
  "reason": "Wrong email address"
}

→ 200 OK { "status": "cancelled" }
```

For agent jobs, rejection can optionally route to a revision:

```
POST /api/v1/jobs/{id}/reject
Content-Type: application/json

{
  "rejected_by": "jeremy",
  "reason": "Wrong email address",
  "revise": true,
  "feedback": "The email should go to sales@bigclient.com, not the CEO"
}
```

When `revise: true`, the server re-enqueues the agent job with the rejection feedback appended to the checkpoint, so the next iteration can incorporate it.

### Approval policies

Rules that automatically hold jobs matching certain conditions:

```
POST /api/v1/approval-policies
Content-Type: application/json

{
  "name": "hold-expensive-agent-actions",
  "queue_pattern": "agents.*",
  "conditions": {
    "agent_iteration_gt": 10,
    "cost_usd_gt": 0.50,
    "hold_payload_action_in": ["send_email", "delete", "payment", "api_call"]
  },
  "match": "any"
}
```

**`match` logic:**
- `any` — hold if ANY condition matches (default, safer)
- `all` — hold only if ALL conditions match (more permissive)

Policies are evaluated server-side when an agent returns `agent_status: "continue"`. Low-risk iterations proceed automatically; high-risk ones pause for review.

### Schema additions

```sql
-- Add to jobs table
ALTER TABLE jobs ADD COLUMN hold_reason TEXT;
ALTER TABLE jobs ADD COLUMN hold_payload TEXT;      -- JSON
ALTER TABLE jobs ADD COLUMN hold_timeout TEXT;
ALTER TABLE jobs ADD COLUMN hold_timeout_action TEXT DEFAULT 'cancel';

-- Approval log
CREATE TABLE approvals (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    action     TEXT NOT NULL,                -- 'approved', 'rejected'
    actor      TEXT,
    note       TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_approvals_job ON approvals(job_id);

-- Approval policies
CREATE TABLE approval_policies (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE,
    queue_pattern  TEXT NOT NULL,            -- glob pattern: 'agents.*'
    conditions     TEXT NOT NULL,            -- JSON
    match_logic    TEXT NOT NULL DEFAULT 'any',
    enabled        INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
```

---

## Job dependencies

Jobs can declare dependencies on other jobs via `depends_on`. A dependent job stays in `pending` until all its dependencies complete. This covers sequential processing pipelines without the server owning result forwarding or pipeline definitions — workers read the upstream job's result and enqueue the next step themselves.

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "llm.validate",
  "payload": { "validation_rules": ["check_dates", "check_amounts"], "upstream_job": "job_01HX..." },
  "depends_on": ["job_01HX..."]
}
```

Jobs share a `chain_id` for UI grouping and tracing. The `chain_step` field tracks position in the sequence.

Corvo intentionally stops short of workflow orchestration (no DAGs, no auto-result-forwarding, no `then` config). The server manages execution order; workers own the data flow between steps.

### Schema

```sql
ALTER TABLE jobs ADD COLUMN chain_config TEXT;   -- JSON: dependency config
ALTER TABLE jobs ADD COLUMN chain_id TEXT;        -- links all jobs in a chain
ALTER TABLE jobs ADD COLUMN chain_step INTEGER;   -- 0, 1, 2, ...
CREATE INDEX idx_jobs_chain ON jobs(chain_id) WHERE chain_id IS NOT NULL;
```

---

## Result caching via unique jobs

Redundant LLM calls can be avoided using the existing unique jobs mechanism. Enqueue with a `unique_key` derived from the request (e.g. a hash of the prompt) and a `unique_period` matching your desired cache TTL. If a completed job with that key exists within the window, the enqueue returns the existing job and its result — no new work is dispatched.

This keeps caching decisions in the caller (who knows what makes two requests "the same") rather than adding server-side cache matching logic. See the unique jobs section in [DESIGN.md](./DESIGN.md) for details.

---

## Tool execution as child jobs

When an agent's LLM response includes tool calls, the worker can enqueue them as child jobs. Tools execute in parallel with their own retries, timeouts, and audit trails.

```
POST /api/v1/enqueue/batch
Content-Type: application/json

{
  "jobs": [
    {
      "queue": "tools.web_search",
      "payload": { "query": "Acme Corp competitors 2026" },
      "parent_id": "job_agent_01HX..."
    },
    {
      "queue": "tools.web_search",
      "payload": { "query": "Acme Corp market share" },
      "parent_id": "job_agent_01HX..."
    }
  ],
  "batch": {
    "callback_queue": "agents.research",
    "callback_payload": { "resume_from": "job_agent_01HX..." }
  }
}
```

This uses the existing batch mechanism from [DESIGN.md](./DESIGN.md#batches). The `parent_id` is a new optional field that links child jobs to their parent for UI grouping and tracing.

Benefits over executing tools inline in the worker:
- **Parallelism** — tools run concurrently as separate jobs
- **Isolation** — a slow tool doesn't block other tools or the agent
- **Visibility** — see which tools ran, what they returned, how long they took
- **Retries** — each tool has its own retry policy
- **Rate limiting** — tool queues can have their own concurrency and rate limits
- **Approval** — tool queues can require approval via policies (e.g., `tools.send_email` requires human review)

### Schema

```sql
ALTER TABLE jobs ADD COLUMN parent_id TEXT REFERENCES jobs(id);
CREATE INDEX idx_jobs_parent ON jobs(parent_id) WHERE parent_id IS NOT NULL;
```

---

## UI additions

### Cost dashboard

A new top-level view in the UI showing spend across queues, models, and time:

```
┌──────────────────────────────────────────────────────────────────────┐
│  AI Cost Dashboard                          Period: [Last 7 days ▾] │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Total spend: $59.33        Budget remaining: $140.67 / $200.00     │
│  ████████████████████████████░░░░░░░░░░░░░ 70% of weekly budget     │
│                                                                      │
│  Cost by queue                                                       │
│  ┌────────────────────┬──────────┬───────────┬──────────┬──────────┐│
│  │ Queue              │ Cost     │ Jobs      │ $/job    │ Trend    ││
│  ├────────────────────┼──────────┼───────────┼──────────┼──────────┤│
│  │ agents.research    │ $47.23   │ 1,204     │ $0.039   │ ↑ 12%    ││
│  │ extraction.invoices│ $12.10   │ 4,521     │ $0.003   │ ↓ 3%     ││
│  └────────────────────┴──────────┴───────────┴──────────┴──────────┘│
│                                                                      │
│  Cost by model                                                       │
│  ┌───────────────────────────┬──────────┬───────────────────────┐   │
│  │ Model                     │ Cost     │ Tokens (in/out)       │   │
│  ├───────────────────────────┼──────────┼───────────────────────┤   │
│  │ claude-sonnet-4-5         │ $41.20   │ 2.1M / 890K           │   │
│  │ gpt-4o                    │ $15.83   │ 1.8M / 420K           │   │
│  │ claude-haiku-4-5          │ $2.30    │ 890K / 310K           │   │
│  └───────────────────────────┴──────────┴───────────────────────┘   │
│                                                                      │
│  Cache                                                               │
│  Hit rate: 24.3%    Estimated savings: $18.40                       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Agent job detail view

Extended job detail for agent jobs showing the iteration history:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Agent: job_01HX7Y... (agents.research)      [Cancel] [Replay ▾]   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Goal: "Find the top 3 competitors to Acme Corp"                   │
│  Status: ● active (iteration 4 of 20)                               │
│  Cost:   $0.42 / $1.00 budget                                       │
│  ████████████████████░░░░░░░░░░░░░░░░ 42%                           │
│                                                                      │
│  Iterations                                                          │
│  ┌─────┬──────────┬───────────────────────────────────┬──────┬─────┐│
│  │ #   │ Model    │ Action                            │ Cost │ Time││
│  ├─────┼──────────┼───────────────────────────────────┼──────┼─────┤│
│  │ 1   │ sonnet   │ Called web_search("Acme Corp      │$0.02 │ 1.2s││
│  │     │          │ competitors")                     │      │     ││
│  │ 2   │ sonnet   │ Called web_search("CompA products │$0.01 │ 0.8s││
│  │     │          │ 2026"), web_search("CompB...")     │      │     ││
│  │ 3   │ sonnet   │ Called web_search("CompC market   │$0.02 │ 1.4s││
│  │     │          │ share")                           │      │     ││
│  │ 4   │ sonnet   │ ● Running...                      │  ... │ ... ││
│  └─────┴──────────┴───────────────────────────────────┴──────┴─────┘│
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Held jobs view

A dedicated view (or filter) for jobs awaiting approval:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Held Jobs (3 awaiting review)                                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ ⏸ job_01HX... agents.research                       held 2m  │  │
│  │                                                                │  │
│  │ Reason: Budget limit reached ($1.02 of $1.00 max)             │  │
│  │ Iterations: 12 of 20   Cost: $1.02                            │  │
│  │                                                                │  │
│  │ [Approve (increase budget)] [Reject] [View job]               │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ ⏸ job_01HY... agents.outreach                      held 14m  │  │
│  │                                                                │  │
│  │ Reason: Agent wants to send email to customer@acme.com        │  │
│  │                                                                │  │
│  │ Draft:                                                         │  │
│  │ "Dear Customer, I wanted to follow up on our conversation..." │  │
│  │                                                                │  │
│  │ [Approve] [Reject] [Reject & Revise] [View job]              │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## CLI additions

```bash
# Usage and cost
corvo usage                                    # summary for last 24h
corvo usage --period 7d --group-by queue       # cost per queue
corvo usage --period 30d --group-by model      # cost per model
corvo usage --period 7d --group-by tag:tenant  # cost per tenant

# Budgets
corvo budget list                              # show all budgets
corvo budget set agents.research --daily 50    # set daily budget
corvo budget set agents.research --per-job 2   # set per-job budget

# Held jobs
corvo held                                     # list held jobs
corvo approve job_01HX...                      # approve a held job
corvo reject job_01HX...                       # reject a held job
corvo reject job_01HX... --revise "fix the email address"

# Agent replay
corvo replay job_01HX... --from 3              # replay from iteration 3
corvo replay job_01HX... --from 3 --set agent.max_iterations=30

# Cache
corvo cache stats                              # cache hit rate + savings
corvo cache clear --queue llm.chat             # clear cache for a queue
```

---

## Implementation plan

These features are additive and can be built incrementally after the core MVP from [DESIGN.md](./DESIGN.md#implementation-plan).

### Phase 2a — AI foundations (after core MVP)

- [x] `job_usage` table + usage reporting on ack and heartbeat
- [x] Usage summary endpoints (`/api/v1/usage/summary`)
- [x] Cost dashboard in UI
- [x] CLI: `corvo usage`
- [x] `held` job state + approve/reject endpoints
- [x] Held jobs view in UI
- [x] CLI: `corvo held`, `corvo approve`, `corvo reject`
- [x] Budget table + enforcement on fetch and ack
- [x] CLI: `corvo budget`

### Phase 2b — Agent loop

- [x] `agent` config on enqueue
- [x] `agent_status` handling on ack (continue, done, hold)
- [x] `job_iterations` table + iteration tracking
- [x] Server-side guardrail enforcement (max iterations, max cost)
- [ ] Agent job detail view in UI (iteration history)
- [x] Replay endpoint + CLI

### Phase 2c — Dependencies and caching

- [x] Job dependencies (`depends_on` + `chain_id`/`chain_step`)
- [ ] Chain tracking in UI (dependency visualization)
- [x] Result caching via unique jobs (covered by existing `unique_key` + `unique_period`)
- [x] `parent_id` for tool-as-child-job pattern
- [x] Approval policies (auto-hold rules)

---

## What this is NOT

This document extends Corvo with AI-aware features but does not make it:

- **An agent framework** — Corvo doesn't write prompts, call LLMs, or choose tools. Your worker code does that. Corvo provides the execution infrastructure: retries, rate limits, cost control, human approval, observability.
- **An LLM gateway/proxy** — Corvo doesn't proxy API calls to LLM providers. Workers call providers directly. Corvo manages the *jobs* that wrap those calls.
- **A prompt management system** — Prompts live in your code or your prompt store. Corvo tracks which model and prompt version were used (via tags) for analysis, but doesn't manage prompt content.
- **An eval platform** — Corvo does not score or evaluate LLM outputs. Use a dedicated eval tool for that.
