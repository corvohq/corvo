import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { ClusterStatus } from "@/lib/types";

function clusterHealthy(status: ClusterStatus): boolean {
  if (status.status === "healthy") return true;
  // Real cluster mode: healthy if state is "Leader" or "Follower"
  if (status.state && ["leader", "follower"].includes(status.state.toLowerCase())) return true;
  return false;
}

export function ClusterPanel({ status }: { status: ClusterStatus }) {
  const healthy = clusterHealthy(status);
  const displayStatus = status.status || (healthy ? "healthy" : status.state || "unknown");

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle className="text-sm">Cluster</CardTitle>
          <div className="flex items-center gap-2">
            <Badge
              variant="secondary"
              className={
                healthy
                  ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                  : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
              }
            >
              {displayStatus}
            </Badge>
            <Badge variant="outline">{status.mode}</Badge>
            {status.state && <Badge variant="outline">{status.state}</Badge>}
          </div>
        </div>
      </CardHeader>
      <CardContent>
        {status.nodes && status.nodes.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Node</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Status</TableHead>
                {status.nodes[0]?.address && <TableHead>Address</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {status.nodes.map((node, i) => {
                const nodeStatus = node.status || (node.role ? "ok" : "voter");
                const nodeHealthy = node.status === "healthy" || (!node.status && node.role != null);
                return (
                  <TableRow key={node.id || i}>
                    <TableCell className="font-mono text-xs">
                      {node.id || `node-${i}`}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline" className="capitalize">
                        {node.role || (node.voter ? "voter" : "non-voter")}
                      </Badge>
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant="secondary"
                        className={
                          nodeHealthy
                            ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                            : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
                        }
                      >
                        {nodeStatus}
                      </Badge>
                    </TableCell>
                    {node.address && (
                      <TableCell className="font-mono text-xs">
                        {node.address}
                      </TableCell>
                    )}
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">Single node mode</p>
        )}
      </CardContent>
    </Card>
  );
}
