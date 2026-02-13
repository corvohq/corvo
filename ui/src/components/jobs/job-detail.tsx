import { Link } from "react-router-dom";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { StateBadge } from "./state-badge";
import { JobPayload } from "./job-payload";
import { JobTimeline } from "./job-timeline";
import { JobProgress } from "./job-progress";
import { ErrorHistory } from "./error-history";
import { PRIORITY_LABELS } from "@/lib/constants";
import { timeAgo } from "@/lib/utils";
import {
  useRetryJob,
  useCancelJob,
  useDeleteJob,
  useReplayJob,
} from "@/hooks/use-mutations";
import type { Job } from "@/lib/types";
import {
  RotateCcw,
  XCircle,
  Trash2,
  ArrowRightLeft,
  Copy,
} from "lucide-react";
import { useState } from "react";
import { MoveDialog } from "@/components/dialogs/move-dialog";
import { EnqueueDialog } from "@/components/dialogs/enqueue-dialog";
import { useJobIterations } from "@/hooks/use-job-iterations";
import { IterationTable } from "@/components/ai/iteration-table";
import { ScoreSummary } from "@/components/ai/score-summary";
import { StreamOutput } from "@/components/ai/stream-output";

export function JobDetail({ job }: { job: Job }) {
  const retryJob = useRetryJob();
  const cancelJob = useCancelJob();
  const deleteJob = useDeleteJob();
  const replayJob = useReplayJob();
  const { data: iterations = [], isLoading: isIterationsLoading } = useJobIterations(job.id);
  const [moveOpen, setMoveOpen] = useState(false);
  const [cloneOpen, setCloneOpen] = useState(false);

  const canRetry = ["dead", "cancelled", "scheduled"].includes(job.state);
  const canCancel = ["pending", "active", "retrying", "scheduled"].includes(
    job.state,
  );

  const retryLabel = job.state === "scheduled" ? "Run Now" : "Retry";
  const resultObj =
    job.result && typeof job.result === "object" && !Array.isArray(job.result)
      ? (job.result as Record<string, unknown>)
      : {};
  const scores =
    resultObj.scores && typeof resultObj.scores === "object" && !Array.isArray(resultObj.scores)
      ? (resultObj.scores as Record<string, number>)
      : {};
  const outputText =
    typeof resultObj.output === "string"
      ? resultObj.output
      : typeof resultObj.text === "string"
        ? resultObj.text
        : typeof resultObj.summary === "string"
          ? resultObj.summary
          : "";
  const isAgentJob = !!job.agent;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="font-mono text-lg font-semibold">{job.id}</h1>
          <div className="mt-1 flex items-center gap-2">
            <StateBadge state={job.state} />
            <Badge variant="outline">
              {PRIORITY_LABELS[job.priority] || "Normal"}
            </Badge>
          </div>
        </div>
        <div className="flex gap-2">
          {canRetry && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => retryJob.mutate(job.id)}
              disabled={retryJob.isPending}
            >
              <RotateCcw className="mr-1 h-3 w-3" /> {retryLabel}
            </Button>
          )}
          {canCancel && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => cancelJob.mutate(job.id)}
              disabled={cancelJob.isPending}
            >
              <XCircle className="mr-1 h-3 w-3" /> Cancel
            </Button>
          )}
          <Button
            variant="outline"
            size="sm"
            onClick={() => setCloneOpen(true)}
          >
            <Copy className="mr-1 h-3 w-3" /> Clone
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => setMoveOpen(true)}
          >
            <ArrowRightLeft className="mr-1 h-3 w-3" /> Move
          </Button>
          <Button
            variant="destructive"
            size="sm"
            onClick={() => deleteJob.mutate(job.id)}
            disabled={deleteJob.isPending}
          >
            <Trash2 className="mr-1 h-3 w-3" /> Delete
          </Button>
        </div>
      </div>

      {/* Progress */}
      {job.progress && (
        <JobProgress
          current={job.progress.current}
          total={job.progress.total}
          message={job.progress.message}
        />
      )}

      {/* Metadata */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Metadata</CardTitle>
        </CardHeader>
        <CardContent>
          <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
            <div>
              <dt className="text-muted-foreground">Queue</dt>
              <dd>
                <Link
                  to={`/ui/queues/${job.queue}`}
                  className="text-primary hover:underline"
                >
                  {job.queue}
                </Link>
              </dd>
            </div>
            <div>
              <dt className="text-muted-foreground">Attempt</dt>
              <dd>
                {job.attempt} / {job.max_retries + 1}
              </dd>
            </div>
            {job.worker_id && (
              <div>
                <dt className="text-muted-foreground">Worker</dt>
                <dd className="font-mono text-xs">
                  {job.worker_id}
                  {job.hostname && (
                    <span className="text-muted-foreground">
                      {" "}
                      ({job.hostname})
                    </span>
                  )}
                </dd>
              </div>
            )}
            {job.unique_key && (
              <div>
                <dt className="text-muted-foreground">Unique Key</dt>
                <dd className="font-mono text-xs">{job.unique_key}</dd>
              </div>
            )}
            {job.batch_id && (
              <div>
                <dt className="text-muted-foreground">Batch</dt>
                <dd className="font-mono text-xs">{job.batch_id}</dd>
              </div>
            )}
            <div>
              <dt className="text-muted-foreground">Created</dt>
              <dd>{timeAgo(job.created_at)}</dd>
            </div>
            {job.started_at && (
              <div>
                <dt className="text-muted-foreground">Started</dt>
                <dd>{timeAgo(job.started_at)}</dd>
              </div>
            )}
            {job.completed_at && (
              <div>
                <dt className="text-muted-foreground">Completed</dt>
                <dd>{timeAgo(job.completed_at)}</dd>
              </div>
            )}
            {job.retry_backoff && job.retry_backoff !== "none" && (
              <div>
                <dt className="text-muted-foreground">Retry Backoff</dt>
                <dd>
                  {job.retry_backoff} ({job.retry_base_delay_ms}ms -{" "}
                  {job.retry_max_delay_ms}ms)
                </dd>
              </div>
            )}
            {job.agent && (
              <>
                <div>
                  <dt className="text-muted-foreground">Agent Iteration</dt>
                  <dd>
                    {job.agent.iteration || 0}
                    {job.agent.max_iterations ? ` / ${job.agent.max_iterations}` : ""}
                  </dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Agent Cost</dt>
                  <dd>
                    ${((job.agent.total_cost_usd || 0)).toFixed(4)}
                    {job.agent.max_cost_usd ? ` / $${job.agent.max_cost_usd.toFixed(4)}` : ""}
                  </dd>
                </div>
              </>
            )}
          </dl>

          {job.tags && Object.keys(job.tags).length > 0 && (
            <div className="mt-4">
              <p className="mb-2 text-sm text-muted-foreground">Tags</p>
              <div className="flex flex-wrap gap-1">
                {Object.entries(job.tags).map(([k, v]) => (
                  <Badge key={k} variant="secondary" className="text-xs">
                    {k}={v}
                  </Badge>
                ))}
              </div>
            </div>
          )}
          {job.hold_reason && (
            <div className="mt-4">
              <p className="mb-1 text-sm text-muted-foreground">Hold Reason</p>
              <p className="rounded bg-muted px-2 py-1 text-sm">{job.hold_reason}</p>
            </div>
          )}
        </CardContent>
      </Card>

      {Object.keys(scores).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Scores</CardTitle>
          </CardHeader>
          <CardContent>
            <ScoreSummary scores={scores} />
          </CardContent>
        </Card>
      )}

      {outputText && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Output</CardTitle>
          </CardHeader>
          <CardContent>
            <StreamOutput content={outputText} />
          </CardContent>
        </Card>
      )}

      {isAgentJob && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Agent Iterations</CardTitle>
          </CardHeader>
          <CardContent>
            {isIterationsLoading ? (
              <p className="py-4 text-sm text-muted-foreground">Loading iterations...</p>
            ) : (
              <IterationTable
                iterations={iterations}
                replaying={replayJob.isPending}
                onReplay={(from) => replayJob.mutate({ id: job.id, from })}
              />
            )}
          </CardContent>
        </Card>
      )}

      {/* Payload */}
      <JobPayload label="Payload" data={job.payload} defaultOpen />

      {/* Result */}
      <JobPayload label="Result" data={job.result} />

      {/* Checkpoint */}
      <JobPayload label="Checkpoint" data={job.checkpoint} />

      {/* Errors */}
      <ErrorHistory errors={job.errors || []} />

      <Separator />

      {/* Timeline */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Timeline</CardTitle>
        </CardHeader>
        <CardContent>
          <JobTimeline job={job} />
        </CardContent>
      </Card>

      <MoveDialog
        open={moveOpen}
        onOpenChange={setMoveOpen}
        jobId={job.id}
      />

      <EnqueueDialog
        open={cloneOpen}
        onOpenChange={setCloneOpen}
        initialValues={{
          queue: job.queue,
          payload: job.payload,
          priority: job.priority,
          uniqueKey: job.unique_key,
          maxRetries: job.max_retries,
        }}
      />
    </div>
  );
}
