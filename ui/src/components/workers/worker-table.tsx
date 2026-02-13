import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { timeAgo } from "@/lib/utils";
import type { Worker } from "@/lib/types";

export function WorkerTable({ workers }: { workers: Worker[] }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Worker ID</TableHead>
          <TableHead>Hostname</TableHead>
          <TableHead>Queues</TableHead>
          <TableHead>Last Heartbeat</TableHead>
          <TableHead>Uptime</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {workers.map((w) => (
          <TableRow key={w.id}>
            <TableCell className="font-mono text-xs">{w.id}</TableCell>
            <TableCell>{w.hostname || "-"}</TableCell>
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
        ))}
        {workers.length === 0 && (
          <TableRow>
            <TableCell colSpan={5} className="text-center text-muted-foreground">
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
