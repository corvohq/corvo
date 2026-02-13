# AI Extras

Infrastructure-only AI workflow extensions for Jobbie.

This document intentionally stays within the design boundary from `docs/DESIGN.md`:
- Jobbie provides execution infrastructure.
- Workers own prompts, LLM calls, and tool choice.

## Scope

In scope:
- queue/runtime safety controls
- human review infrastructure
- observability and queryability
- cache behavior in enqueue/fetch/ack workflow

Out of scope:
- prompt authoring/version management product
- model selection/canary decisioning product logic
- evaluator orchestration platform
- SLO/incident management product layer

## Priority Backlog

1. Rich approval policies
- Status: implemented baseline.
- Next: expand predicates (cost range, payload field matches, tag patterns, queue patterns), add dry-run mode, add policy hit diagnostics endpoint.

2. Trace UI improvements
- Status: trace storage and display implemented.
- Next: iteration-to-iteration diff and tool/action timeline view in job detail.

3. Exact-match caching at enqueue
- Status: usage has cache token metrics; enqueue cache-hit behavior not implemented.
- Next: add payload-hash cache key lookup on enqueue, short-circuit completed response on hit, TTL-aware invalidation.

4. Budget warning signal in heartbeat
- Status: implemented (`budget_exceeded` in heartbeat response).
- Next: document in API/CLI help and surface clearly in worker examples.

5. Better usage tag querying
- Status: queue/model grouping exists.
- Next: add `group_by=tag:<key>` support to usage summary with tests and docs.

## Implementation Order

1. Trace UI improvements
2. Exact-match caching at enqueue
3. Usage `group_by=tag:<key>`
4. Approval policy predicate expansion and diagnostics
5. Budget warning docs/examples polish
