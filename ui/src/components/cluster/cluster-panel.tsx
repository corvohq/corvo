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

export function ClusterPanel({ status }: { status: ClusterStatus }) {
  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle className="text-sm">Cluster</CardTitle>
          <div className="flex items-center gap-2">
            <Badge
              variant="secondary"
              className={
                status.status === "healthy"
                  ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                  : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
              }
            >
              {status.status}
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
              {status.nodes.map((node, i) => (
                <TableRow key={node.id || i}>
                  <TableCell className="font-mono text-xs">
                    {node.id || `node-${i}`}
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline" className="capitalize">
                      {node.role}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <Badge
                      variant="secondary"
                      className={
                        node.status === "healthy"
                          ? "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                          : "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
                      }
                    >
                      {node.status}
                    </Badge>
                  </TableCell>
                  {node.address && (
                    <TableCell className="font-mono text-xs">
                      {node.address}
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">Single node mode</p>
        )}
      </CardContent>
    </Card>
  );
}
