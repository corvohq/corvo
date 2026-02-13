import { useNavigate } from "react-router-dom";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatNumber } from "@/lib/utils";
import { usePauseQueue, useResumeQueue } from "@/hooks/use-mutations";
import type { QueueInfo } from "@/lib/types";
import { Pause, Play } from "lucide-react";

function latencyDisplay(oldestPendingAt?: string): { text: string; className: string } | null {
  if (!oldestPendingAt) return null;
  const ms = Date.now() - new Date(oldestPendingAt).getTime();
  if (ms < 0) return null;
  const seconds = Math.floor(ms / 1000);
  let text: string;
  if (seconds < 60) text = `${seconds}s`;
  else if (seconds < 3600) text = `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  else text = `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;

  let className = "";
  if (seconds > 300) className = "text-destructive font-medium";
  else if (seconds > 60) className = "text-orange-600 dark:text-orange-400 font-medium";

  return { text, className };
}

export function QueueTable({ queues }: { queues: QueueInfo[] }) {
  const navigate = useNavigate();
  const pauseQueue = usePauseQueue();
  const resumeQueue = useResumeQueue();

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Name</TableHead>
          <TableHead className="text-right">Pending</TableHead>
          <TableHead className="text-right">Active</TableHead>
          <TableHead className="text-right">Completed</TableHead>
          <TableHead className="text-right">Dead</TableHead>
          <TableHead className="text-right">Scheduled</TableHead>
          <TableHead className="text-right">Retrying</TableHead>
          <TableHead>Latency</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="w-[60px]"></TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {queues.map((q) => {
          const lat = latencyDisplay(q.oldest_pending_at);
          return (
            <TableRow
              key={q.name}
              className="cursor-pointer"
              onClick={() => navigate(`/ui/queues/${q.name}`)}
            >
              <TableCell className="font-medium">{q.name}</TableCell>
              <TableCell className="text-right font-mono text-sm">
                {formatNumber(q.pending)}
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {formatNumber(q.active)}
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {formatNumber(q.completed)}
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {q.dead > 0 ? (
                  <span className="text-destructive">{formatNumber(q.dead)}</span>
                ) : (
                  formatNumber(q.dead)
                )}
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {formatNumber(q.scheduled)}
              </TableCell>
              <TableCell className="text-right font-mono text-sm">
                {formatNumber(q.retrying)}
              </TableCell>
              <TableCell className="font-mono text-sm">
                {lat ? (
                  <span className={lat.className}>{lat.text}</span>
                ) : (
                  <span className="text-muted-foreground">-</span>
                )}
              </TableCell>
              <TableCell>
                {q.paused ? (
                  <Badge variant="secondary">Paused</Badge>
                ) : (
                  <Badge
                    variant="secondary"
                    className="bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                  >
                    Active
                  </Badge>
                )}
              </TableCell>
              <TableCell onClick={(e) => e.stopPropagation()}>
                {q.paused ? (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-7 w-7"
                    onClick={() => resumeQueue.mutate(q.name)}
                  >
                    <Play className="h-3.5 w-3.5" />
                  </Button>
                ) : (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-7 w-7"
                    onClick={() => pauseQueue.mutate(q.name)}
                  >
                    <Pause className="h-3.5 w-3.5" />
                  </Button>
                )}
              </TableCell>
            </TableRow>
          );
        })}
        {queues.length === 0 && (
          <TableRow>
            <TableCell colSpan={10} className="text-center text-muted-foreground">
              No queues found
            </TableCell>
          </TableRow>
        )}
      </TableBody>
    </Table>
  );
}
