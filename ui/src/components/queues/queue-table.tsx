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
          <TableHead>Status</TableHead>
          <TableHead className="w-[60px]"></TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {queues.map((q) => (
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
        ))}
        {queues.length === 0 && (
          <TableRow>
            <TableCell colSpan={9} className="text-center text-muted-foreground">
              No queues found
            </TableCell>
          </TableRow>
        )}
      </TableBody>
    </Table>
  );
}
