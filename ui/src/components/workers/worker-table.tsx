import { useState, useEffect } from "react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { timeAgo } from "@/lib/utils";
import type { Worker } from "@/lib/types";

function workerStatus(lastHeartbeat: string) {
  const seconds = (Date.now() - new Date(lastHeartbeat).getTime()) / 1000;
  if (seconds > 300)
    return { label: "Offline", className: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200" };
  if (seconds > 60)
    return { label: "Stale", className: "bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200" };
  return { label: "Healthy", className: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200" };
}

export function WorkerTable({ workers }: { workers: Worker[] }) {
  const [, setTick] = useState(0);

  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 10_000);
    return () => clearInterval(id);
  }, []);

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Worker ID</TableHead>
          <TableHead>Hostname</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Queues</TableHead>
          <TableHead>Last Heartbeat</TableHead>
          <TableHead>Uptime</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {workers.map((w) => {
          const status = workerStatus(w.last_heartbeat);
          return (
            <TableRow key={w.id}>
              <TableCell className="font-mono text-xs">{w.id}</TableCell>
              <TableCell>{w.hostname || "-"}</TableCell>
              <TableCell>
                <Badge variant="secondary" className={status.className}>
                  {status.label}
                </Badge>
              </TableCell>
              <TableCell className="text-xs">
                {w.queues ? tryParseQueues(w.queues) : "-"}
              </TableCell>
              <TableCell className="text-xs text-muted-foreground">
                {timeAgo(w.last_heartbeat)}
              </TableCell>
              <TableCell className="text-xs text-muted-foreground">
                {timeAgo(w.started_at)}
              </TableCell>
            </TableRow>
          );
        })}
        {workers.length === 0 && (
          <TableRow>
            <TableCell colSpan={6} className="text-center text-muted-foreground">
              No workers connected
            </TableCell>
          </TableRow>
        )}
      </TableBody>
    </Table>
  );
}

function tryParseQueues(raw: string): string {
  try {
    const arr = JSON.parse(raw);
    if (Array.isArray(arr)) return arr.join(", ");
  } catch {
    // ignore
  }
  return raw;
}
