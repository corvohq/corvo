import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { QueueTable } from "@/components/queues/queue-table";
import { WorkerTable } from "@/components/workers/worker-table";
import { ClusterPanel } from "@/components/cluster/cluster-panel";
import { StateBadge } from "@/components/jobs/state-badge";
import { ThroughputChart } from "@/components/charts/throughput-chart";
import { EnqueueDialog } from "@/components/dialogs/enqueue-dialog";
import { useQueues } from "@/hooks/use-queues";
import { useWorkers } from "@/hooks/use-workers";
import { useCluster } from "@/hooks/use-cluster";
import { useSearch } from "@/hooks/use-search";
import { timeAgo, truncateId } from "@/lib/utils";
import { useNavigate } from "react-router-dom";
import { Plus } from "lucide-react";

function maxLatency(queues: { oldest_pending_at?: string }[]): string | null {
  let maxMs = 0;
  for (const q of queues) {
    if (!q.oldest_pending_at) continue;
    const ms = Date.now() - new Date(q.oldest_pending_at).getTime();
    if (ms > maxMs) maxMs = ms;
  }
  if (maxMs === 0) return null;
  const seconds = Math.floor(maxMs / 1000);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export default function Dashboard() {
  const [enqueueOpen, setEnqueueOpen] = useState(false);
  const { data: queues, isLoading: queuesLoading } = useQueues();
  const { data: workers, isLoading: workersLoading } = useWorkers();
  const { data: cluster } = useCluster();
  const { data: recentDead } = useSearch({
    state: ["dead"],
    limit: 5,
    sort: "created_at",
    order: "desc",
  });
  const navigate = useNavigate();

  const latency = queues ? maxLatency(queues) : null;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Dashboard</h1>
        <Button size="sm" onClick={() => setEnqueueOpen(true)}>
          <Plus className="mr-1 h-4 w-4" /> Enqueue Job
        </Button>
      </div>
      <EnqueueDialog open={enqueueOpen} onOpenChange={setEnqueueOpen} />

      {/* Summary stats */}
      {queues && (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-5">
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-muted-foreground">
                Total Pending
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold">
                {queues.reduce((a, q) => a + q.pending, 0)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-muted-foreground">
                Active
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold">
                {queues.reduce((a, q) => a + q.active, 0)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-muted-foreground">
                Dead
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold text-destructive">
                {queues.reduce((a, q) => a + q.dead, 0)}
              </p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-muted-foreground">
                Queues
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold">{queues.length}</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm text-muted-foreground">
                Max Latency
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold">
                {latency || "-"}
              </p>
            </CardContent>
          </Card>
        </div>
      )}

      {/* Throughput chart */}
      <ThroughputChart />

      {/* Queues */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Queues</CardTitle>
        </CardHeader>
        <CardContent>
          {queuesLoading ? (
            <p className="py-4 text-center text-sm text-muted-foreground">
              Loading...
            </p>
          ) : (
            <QueueTable queues={queues || []} />
          )}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Recent failures */}
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Recent Failures</CardTitle>
          </CardHeader>
          <CardContent>
            {recentDead?.jobs && recentDead.jobs.length > 0 ? (
              <div className="space-y-2">
                {recentDead.jobs.map((job) => (
                  <div
                    key={job.id}
                    className="flex cursor-pointer items-center justify-between rounded-md border p-3 hover:bg-muted/50"
                    onClick={() => navigate(`/ui/jobs/${job.id}`)}
                  >
                    <div className="flex items-center gap-2">
                      <StateBadge state={job.state} />
                      <span className="font-mono text-xs">
                        {truncateId(job.id)}
                      </span>
                      <span className="text-xs text-muted-foreground">
                        {job.queue}
                      </span>
                    </div>
                    <span className="text-xs text-muted-foreground">
                      {timeAgo(job.created_at)}
                    </span>
                  </div>
                ))}
              </div>
            ) : (
              <p className="py-4 text-center text-sm text-muted-foreground">
                No recent failures
              </p>
            )}
          </CardContent>
        </Card>

        {/* Workers */}
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Workers</CardTitle>
          </CardHeader>
          <CardContent>
            {workersLoading ? (
              <p className="py-4 text-center text-sm text-muted-foreground">
                Loading...
              </p>
            ) : (
              <WorkerTable workers={workers || []} />
            )}
          </CardContent>
        </Card>
      </div>

      {/* Cluster */}
      {cluster && <ClusterPanel status={cluster} />}
    </div>
  );
}
