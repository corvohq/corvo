# AI Extras

High-value AI workflow extensions beyond the current Phase 2 implementation.

## Priority Backlog

1. Prompt/version as first-class metadata
- Add dedicated fields for `prompt_id`, `prompt_version`, and `experiment` (instead of relying only on tags).
- Use these fields in score/cost/latency breakdowns and comparisons.

2. Automatic eval pipelines
- Add on-complete evaluator hooks that automatically write `job_scores`.
- Add threshold-based pass/fail and regression alerting.

3. Canary rollouts for models/prompts
- Add weighted routing for controlled rollouts (for example `90/10`, `50/50`).
- Add automated score/cost/latency comparison and promote/demote controls.

4. Rich approval policies
- Expand policy predicates for action type, cost range, queue, tags, and payload fields.
- Add dry-run mode and policy-hit diagnostics.

5. Budget degrade workflow
- Add a degrade action that switches to cheaper fallback execution before hold/reject.
- Add burn-rate forecast and budget alerting.

6. Trace tooling
- Add iteration diff view and tool-call timeline.
- Add exportable trace bundles and replay from trace checkpoints.

7. Real caching workflow
- Add enqueue-time cache hit behavior for exact/semantic matching with TTL and invalidation policy.
- Add cache clear endpoints by queue/tag/model.

8. AI SLO and incident workflow
- Add AI SLOs for p95 latency, hold rate, provider-error rate, and cost/job.
- Add alert surfaces in UI and runbook links.

## Suggested Implementation Order

1. Prompt/version metadata
2. Automatic eval pipelines
3. Canary rollouts
4. Rich approval policies
5. Budget degrade workflow
6. Trace tooling
7. Real caching workflow
8. AI SLO and incident workflow
