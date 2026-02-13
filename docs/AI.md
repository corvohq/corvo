# Jobbie AI

First-class support for AI/LLM workloads. Everything in this document is additive to the core design in [DESIGN.md](./DESIGN.md) — no breaking changes to existing APIs, schema, or behavior.

## Why

LLM API calls are the perfect job queue use case: they're slow (seconds, not milliseconds), expensive ($0.01–$1+ per call), flaky (429s, 503s, rate limits), and non-deterministic (same input, different output). Every team building on LLMs ends up reinventing job queue primitives inside their agent framework — retries, rate limiting, cost tracking, timeouts, human approval gates.

Jobbie already handles most of this. This document describes the features that make it *purpose-built* for AI workloads.

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

An agent is a loop: call LLM, get tool calls, execute tools, feed results back, repeat until done. Jobbie models this as an iterative job — each iteration is a discrete unit of work with its own audit trail, and the server enforces guardrails.

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

### Agent trace

Each iteration is recorded as an entry in a new `job_iterations` table:

```sql
CREATE TABLE job_iterations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id      TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    iteration   INTEGER NOT NULL,
    status      TEXT NOT NULL,                -- 'continue', 'done', 'hold', 'failed'
    checkpoint  TEXT,                          -- JSON: accumulated state
    trace       TEXT,                          -- JSON: LLM request/response for this iteration
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

Workers can optionally include a `trace` field in the ack to store the full LLM request/response:

```json
{
  "agent_status": "continue",
  "trace": {
    "request": {
      "model": "claude-sonnet-4-5-20250929",
      "messages": [{"role": "user", "content": "..."}],
      "tools": [{"name": "web_search", "description": "..."}]
    },
    "response": {
      "content": "I'll search for competitors...",
      "tool_calls": [{"name": "web_search", "input": {"query": "Acme Corp competitors"}}]
    }
  },
  "checkpoint": { "messages": [...] },
  "usage": { "input_tokens": 2100, "output_tokens": 340, "cost_usd": 0.015 }
}
```

This is optional — workers that don't send traces still get iteration tracking via the `job_iterations` table.

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
jobbie replay job_01HX7Y --from 3 --set agent.max_iterations=30
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

## Provider-aware rate limiting

LLM providers have rate limits (requests/min, tokens/min) that are shared across all your queues. Jobbie can manage provider-level rate limiting centrally.

### Provider configuration

```
POST /api/v1/providers
Content-Type: application/json

{
  "name": "anthropic",
  "rate_limits": {
    "requests_per_minute": 4000,
    "input_tokens_per_minute": 400000,
    "output_tokens_per_minute": 80000
  }
}
```

```
POST /api/v1/providers
Content-Type: application/json

{
  "name": "openai",
  "rate_limits": {
    "requests_per_minute": 10000,
    "input_tokens_per_minute": 2000000
  }
}
```

### Linking queues to providers

```
POST /api/v1/queues/llm.chat/provider
Content-Type: application/json

{
  "provider": "anthropic"
}
```

Multiple queues can share a provider. The server enforces provider rate limits across all linked queues. When a queue has both its own rate limit and a provider rate limit, the more restrictive one applies.

### How it works

On each `POST /api/v1/fetch` for a provider-linked queue, the server checks the provider's rate limit pool in addition to the queue's own rate limit. Usage data reported via ack/heartbeat updates the token counters.

This is the same sliding-window mechanism from [DESIGN.md](./DESIGN.md#rate-limiting--throttling), extended with token-aware counters:

```sql
CREATE TABLE providers (
    name        TEXT PRIMARY KEY,
    rpm_limit   INTEGER,
    input_tpm_limit  INTEGER,
    output_tpm_limit INTEGER,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Links queues to providers
ALTER TABLE queues ADD COLUMN provider TEXT REFERENCES providers(name);

-- Provider usage window (extends rate_limit_window concept)
CREATE TABLE provider_usage_window (
    provider    TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    recorded_at TEXT NOT NULL
);
CREATE INDEX idx_provider_usage ON provider_usage_window(provider, recorded_at);
```

---

## Model fallback and routing

When an LLM call fails due to a provider issue, automatically retry with a different model or provider.

### Enqueue with routing

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "llm.chat",
  "payload": {
    "messages": [{"role": "user", "content": "Summarize this document..."}]
  },
  "routing": {
    "prefer": "claude-sonnet-4-5-20250929",
    "fallback": ["gpt-4o", "gemini-2.0-flash"],
    "strategy": "fallback_on_error"
  }
}
```

### How it works

The `routing` config is stored on the job. When the job is fetched, the response includes the current target model:

```json
{
  "job_id": "job_01HX...",
  "payload": { "messages": [...] },
  "routing": {
    "target": "claude-sonnet-4-5-20250929",
    "attempt_index": 0
  }
}
```

The worker reads `routing.target` to decide which model to call. If the worker fails with a provider error, the server checks the routing config before applying normal retry logic:

1. If the failure looks like a provider issue (worker includes `"provider_error": true` in the fail request), advance to the next model in the fallback list.
2. If all models have been tried, fall through to normal retry behavior.

```
POST /api/v1/fail/{job_id}
Content-Type: application/json

{
  "error": "Anthropic API 503: Service temporarily unavailable",
  "provider_error": true
}
```

**Routing strategies:**
- `fallback_on_error` — try preferred model first, fall back on provider errors only (default)
- `round_robin` — distribute across all models evenly
- `lowest_cost` — server picks the cheapest model based on usage data (requires provider config with pricing)

### Schema

```sql
-- Routing config stored on the job (in existing payload or new column)
ALTER TABLE jobs ADD COLUMN routing TEXT;           -- JSON: {prefer, fallback, strategy}
ALTER TABLE jobs ADD COLUMN routing_target TEXT;     -- current target model
ALTER TABLE jobs ADD COLUMN routing_index INTEGER DEFAULT 0;  -- position in fallback list
```

---

## Result schema validation

Declare expected output structure at enqueue time. If the LLM returns invalid output, the server automatically retries.

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "extraction.invoices",
  "payload": { "document_url": "s3://...", "prompt": "Extract invoice fields" },
  "result_schema": {
    "type": "object",
    "required": ["vendor", "amount", "date"],
    "properties": {
      "vendor": { "type": "string" },
      "amount": { "type": "number" },
      "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$" }
    }
  }
}
```

On `POST /api/v1/ack/{job_id}`, the server validates `result` against `result_schema` (JSON Schema draft 2020-12). If validation fails:

1. The ack is rejected with a 422 response including the validation errors
2. The job remains `active` — the worker can retry the LLM call and ack again
3. If the worker acks with invalid results and then disconnects, the lease expires and the job retries normally

The worker receives the validation errors so it can include them in a retry prompt:

```json
{
  "error": "result_schema_validation_failed",
  "validation_errors": [
    {"path": "$.date", "message": "does not match pattern ^\\d{4}-\\d{2}-\\d{2}$", "value": "February 11"}
  ]
}
```

This is a server-side safety net. Workers should still use structured output features from LLM providers (tool use, JSON mode), but the server catches what slips through.

---

## Job chaining

Lightweight sequential processing: the result of one job becomes the payload of the next. Not DAG orchestration — just "do A, then do B with A's output."

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "llm.extract",
  "payload": { "document_url": "s3://...", "prompt": "Extract all entities" },
  "then": {
    "queue": "llm.validate",
    "payload": { "validation_rules": ["check_dates", "check_amounts"] },
    "merge_result": true
  }
}
```

When `merge_result: true`, the server creates the next job with a payload that merges the `then.payload` with the previous job's `result`:

```json
{
  "queue": "llm.validate",
  "payload": {
    "validation_rules": ["check_dates", "check_amounts"],
    "previous_result": { "entities": [...] },
    "previous_job_id": "job_01HX..."
  }
}
```

Chains can be multiple steps deep:

```json
{
  "queue": "llm.extract",
  "payload": { "document_url": "s3://..." },
  "then": {
    "queue": "llm.validate",
    "then": {
      "queue": "llm.store",
      "then": {
        "queue": "notifications.send"
      }
    }
  }
}
```

The entire chain is stored on the original job. Each step creates a new job with a `chain_id` linking back to the root, so the full chain is visible in the UI.

If any step fails (after exhausting retries), the chain stops. The dead job shows which step failed and the chain status in the UI.

### Schema

```sql
ALTER TABLE jobs ADD COLUMN chain_config TEXT;   -- JSON: the full `then` config
ALTER TABLE jobs ADD COLUMN chain_id TEXT;        -- links all jobs in a chain
ALTER TABLE jobs ADD COLUMN chain_step INTEGER;   -- 0, 1, 2, ...
CREATE INDEX idx_jobs_chain ON jobs(chain_id) WHERE chain_id IS NOT NULL;
```

---

## Streaming progress

Extend the existing progress and SSE mechanisms to support streaming text output from LLM jobs. Workers send incremental text deltas; the UI renders them in real time.

### Reporting stream deltas

```
POST /api/v1/heartbeat
Content-Type: application/json

{
  "jobs": {
    "job_01HX...": {
      "stream_delta": "The top three competitors are:\n1. "
    }
  }
}
```

The server appends deltas to a buffer and broadcasts them via the existing SSE event stream:

```
event: job.stream
data: {"job_id":"job_01HX...","delta":"The top three competitors are:\n1. ","offset":0}

event: job.stream
data: {"job_id":"job_01HX...","delta":"CompanyA - a leading provider of...","offset":42}
```

UI clients subscribe to the SSE stream and render streaming output in the job detail view. The full assembled text is stored on the job when it completes (as part of `result` or `checkpoint`).

Stream deltas are ephemeral — they're broadcast via SSE and held in a short-lived buffer for late-joining UI clients, but not permanently stored per-delta. Only the final assembled output is persisted.

---

## Output scoring

Downstream consumers or humans can score job results. Scores are aggregated for quality monitoring.

```
POST /api/v1/jobs/{id}/score
Content-Type: application/json

{
  "scores": {
    "relevance": 0.85,
    "accuracy": 0.92,
    "conciseness": 0.78
  },
  "scorer": "human:jeremy"
}
```

Multiple scores can be recorded per job (human review, automated eval, downstream consumer feedback). Score names are freeform — teams define their own dimensions.

### Aggregate queries

```
GET /api/v1/scores/summary?queue=extraction.invoices&period=7d

{
  "queue": "extraction.invoices",
  "period": "7d",
  "dimensions": {
    "accuracy": { "mean": 0.91, "p50": 0.94, "p5": 0.72, "count": 482 },
    "relevance": { "mean": 0.87, "p50": 0.89, "p5": 0.68, "count": 482 }
  }
}
```

Compare scores across tags (for A/B testing prompts):

```
GET /api/v1/scores/compare?queue=llm.summarize&group_by=tag:prompt_version&period=7d

{
  "groups": [
    { "tag": "prompt_version:v2", "accuracy": {"mean": 0.87}, "count": 241 },
    { "tag": "prompt_version:v3-concise", "accuracy": {"mean": 0.93}, "count": 241 }
  ]
}
```

### Schema

```sql
CREATE TABLE job_scores (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    dimension  TEXT NOT NULL,
    value      REAL NOT NULL,
    scorer     TEXT,                          -- 'human:jeremy', 'auto:eval-v2', 'downstream:api'
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_job_scores_job ON job_scores(job_id);
CREATE INDEX idx_job_scores_dimension ON job_scores(dimension, created_at);
```

---

## Semantic caching

Skip redundant LLM calls by caching results for identical (or similar) requests.

### Per-job cache control

```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "llm.chat",
  "payload": { "messages": [{"role": "user", "content": "What is the capital of France?"}] },
  "cache": {
    "enabled": true,
    "ttl": "24h",
    "match": "exact"
  }
}
```

**`match` strategies:**
- `exact` — hash the full payload, match only identical requests (default, simple, no false positives)
- `key` — hash only specific payload fields: `"match": "key", "cache_key_fields": ["messages"]`

On enqueue, if caching is enabled, the server:
1. Computes a cache key (hash of payload or specified fields)
2. Checks for a completed job with the same cache key within the TTL
3. If found: returns immediately with the cached result (the job is created in `completed` state, never sent to a worker)
4. If not found: enqueues normally

**Response when cache hits:**
```json
{
  "job_id": "job_01HX...",
  "status": "completed",
  "cached": true,
  "cached_from": "job_01HW...",
  "result": { "answer": "Paris" }
}
```

### Cache metrics

The usage summary endpoint includes cache stats:

```json
{
  "queue": "llm.chat",
  "cache": {
    "hits": 1247,
    "misses": 3891,
    "hit_rate": 0.243,
    "estimated_savings_usd": 18.40
  }
}
```

### Schema

```sql
ALTER TABLE jobs ADD COLUMN cache_key TEXT;          -- hash of payload (or key fields)
ALTER TABLE jobs ADD COLUMN cache_ttl_seconds INTEGER;
CREATE INDEX idx_jobs_cache ON jobs(queue, cache_key, state, completed_at)
    WHERE cache_key IS NOT NULL;
```

No separate cache table — the jobs table *is* the cache. Completed jobs with a `cache_key` serve as cache entries. The existing job retention/pruning handles cache expiry.

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
│  ▸ Iteration 1 detail (click to expand)                             │
│  ▾ Iteration 2 detail                                               │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │  Request:                                                        ││
│  │  model: claude-sonnet-4-5     tokens: 2,100 in / 340 out        ││
│  │                                                                  ││
│  │  Response:                                                       ││
│  │  "Based on the search results, I can see two main competitors.  ││
│  │   Let me search for more details on each..."                    ││
│  │                                                                  ││
│  │  Tool calls:                                                     ││
│  │  ┌─ web_search("CompA products 2026")                           ││
│  │  │  → 3 results, 1.2s                                           ││
│  │  └─ web_search("CompB products overview")                       ││
│  │     → 5 results, 0.9s                                           ││
│  └──────────────────────────────────────────────────────────────────┘│
│                                                                      │
│  Streaming output                                                    │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │  The top three competitors to Acme Corp are:                     ││
│  │  1. CompanyA - a leading provider of█                            ││
│  └──────────────────────────────────────────────────────────────────┘│
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
jobbie usage                                    # summary for last 24h
jobbie usage --period 7d --group-by queue       # cost per queue
jobbie usage --period 30d --group-by model      # cost per model
jobbie usage --period 7d --group-by tag:tenant  # cost per tenant

# Budgets
jobbie budget list                              # show all budgets
jobbie budget set agents.research --daily 50    # set daily budget
jobbie budget set agents.research --per-job 2   # set per-job budget

# Held jobs
jobbie held                                     # list held jobs
jobbie approve job_01HX...                      # approve a held job
jobbie reject job_01HX...                       # reject a held job
jobbie reject job_01HX... --revise "fix the email address"

# Agent replay
jobbie replay job_01HX... --from 3              # replay from iteration 3
jobbie replay job_01HX... --from 3 --set agent.max_iterations=30

# Providers
jobbie providers                                # list providers
jobbie provider add anthropic --rpm 4000 --input-tpm 400000
jobbie provider add openai --rpm 10000 --input-tpm 2000000

# Scores
jobbie scores job_01HX...                       # show scores for a job
jobbie scores --queue extraction --period 7d    # aggregate scores

# Cache
jobbie cache stats                              # cache hit rate + savings
jobbie cache clear --queue llm.chat             # clear cache for a queue
```

---

## Implementation plan

These features are additive and can be built incrementally after the core MVP from [DESIGN.md](./DESIGN.md#implementation-plan).

### Phase 2a — AI foundations (after core MVP)

- [x] `job_usage` table + usage reporting on ack and heartbeat
- [x] Usage summary endpoints (`/api/v1/usage/summary`)
- [ ] Cost dashboard in UI
- [x] CLI: `jobbie usage`
- [ ] `held` job state + approve/reject endpoints
- [ ] Held jobs view in UI
- [ ] CLI: `jobbie held`, `jobbie approve`, `jobbie reject`
- [ ] Budget table + enforcement on fetch and ack
- [ ] CLI: `jobbie budget`

### Phase 2b — Agent loop

- [ ] `agent` config on enqueue
- [ ] `agent_status` handling on ack (continue, done, hold)
- [ ] `job_iterations` table + iteration tracking
- [ ] Server-side guardrail enforcement (max iterations, max cost)
- [ ] Agent trace storage (optional `trace` field)
- [ ] Agent job detail view in UI (iteration history, expandable traces)
- [ ] Replay endpoint + CLI
- [ ] Streaming progress deltas via SSE
- [ ] Streaming output in job detail UI

### Phase 2c — Provider intelligence

- [ ] Provider table + configuration endpoints
- [ ] Provider-aware rate limiting (token-based sliding window)
- [ ] Queue-to-provider linking
- [ ] Model fallback routing (`routing` config on enqueue)
- [ ] `provider_error` flag on fail
- [ ] CLI: `jobbie providers`

### Phase 2d — Quality and caching

- [ ] Result schema validation (JSON Schema on ack)
- [ ] `result_schema` field on enqueue
- [ ] Job chaining (`then` config)
- [ ] `chain_id` + chain tracking in UI
- [ ] Semantic caching (exact match via payload hash)
- [ ] Cache metrics in usage dashboard
- [ ] CLI: `jobbie cache`
- [ ] `job_scores` table + scoring endpoints
- [ ] Score aggregation + comparison endpoints
- [ ] CLI: `jobbie scores`
- [ ] `parent_id` for tool-as-child-job pattern
- [ ] Approval policies (auto-hold rules)

---

## What this is NOT

This document extends Jobbie with AI-aware features but does not make it:

- **An agent framework** — Jobbie doesn't write prompts, call LLMs, or choose tools. Your worker code does that. Jobbie provides the execution infrastructure: retries, rate limits, cost control, human approval, observability.
- **An LLM gateway/proxy** — Jobbie doesn't proxy API calls to LLM providers. Workers call providers directly. Jobbie manages the *jobs* that wrap those calls.
- **A prompt management system** — Prompts live in your code or your prompt store. Jobbie tracks which model and prompt version were used (via tags) for analysis, but doesn't manage prompt content.
- **An eval platform** — The scoring feature provides basic quality tracking. For serious evals (automated test suites, regression detection, model comparison), use a dedicated eval tool and feed scores back to Jobbie via the scoring API.
