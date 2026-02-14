# AI Extras

Infrastructure-only AI workflow extensions for Corvo.

This document intentionally stays within the design boundary from `docs/DESIGN.md`:
- Corvo provides execution infrastructure.
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

2. Agent job detail UI
- Status: agent iteration tracking implemented. Agent job detail UI with iteration history not yet built.
- Next: agent job detail view with iteration history, iteration-to-iteration diff, and tool/action timeline.

3. Budget warning signal in heartbeat
- Status: implemented (`budget_exceeded` in heartbeat response).
- Next: document in API/CLI help and surface clearly in worker examples.

4. Better usage tag querying
- Status: queue/model grouping exists.
- Next: add `group_by=tag:<key>` support to usage summary with tests and docs.

## Implementation Order

1. Agent job detail UI
2. Usage `group_by=tag:<key>`
3. Approval policy predicate expansion and diagnostics
4. Budget warning docs/examples polish
