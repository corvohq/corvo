import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueueTable } from "@/components/queues/queue-table";
import { WorkerTable } from "@/components/workers/worker-table";
import { ClusterPanel } from "@/components/cluster/cluster-panel";
import { StateBadge } from "@/components/jobs/state-badge";
import { useQueues } from "@/hooks/use-queues";
import { useWorkers } from "@/hooks/use-workers";
import { useCluster } from "@/hooks/use-cluster";
import { useSearch } from "@/hooks/use-search";
import { timeAgo, truncateId } from "@/lib/utils";
import { useNavigate } from "react-router-dom";

export default function Dashboard() {
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

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Dashboard</h1>

      {/* Summary stats */}
      {queues && (
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
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
        </div>
      )}

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
