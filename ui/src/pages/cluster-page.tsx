import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ClusterPanel } from "@/components/cluster/cluster-panel";
import { useCluster } from "@/hooks/use-cluster";

export default function ClusterPage() {
  const { data: cluster, isLoading } = useCluster();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Cluster Status</h1>
        <p className="text-sm text-muted-foreground">
          Raft consensus cluster health and node status.
        </p>
      </div>

      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {cluster && <ClusterPanel status={cluster} />}

      {/* Pipeline and admission stats */}
      {cluster?.pipeline_stats && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Pipeline Stats</CardTitle>
          </CardHeader>
          <CardContent>
            <pre className="overflow-auto rounded bg-muted p-4 text-xs">
              {JSON.stringify(cluster.pipeline_stats, null, 2)}
            </pre>
          </CardContent>
        </Card>
      )}

      {cluster?.admission_stats && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Admission Control</CardTitle>
          </CardHeader>
          <CardContent>
            <pre className="overflow-auto rounded bg-muted p-4 text-xs">
              {JSON.stringify(cluster.admission_stats, null, 2)}
            </pre>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
