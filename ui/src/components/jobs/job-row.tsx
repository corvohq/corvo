import { useNavigate } from "react-router-dom";
import { Checkbox } from "@/components/ui/checkbox";
import { TableRow, TableCell } from "@/components/ui/table";
import { StateBadge } from "./state-badge";
import { PRIORITY_LABELS } from "@/lib/constants";
import { timeAgo, truncateId, truncate } from "@/lib/utils";
import { cn } from "@/lib/utils";
import type { Job } from "@/lib/types";

function scheduledCountdown(scheduledAt?: string): string {
  if (!scheduledAt) return "-";
  const diff = new Date(scheduledAt).getTime() - Date.now();
  if (diff <= 0) return "overdue";
  const minutes = Math.floor(diff / 60000);
  if (minutes < 60) return `in ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `in ${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return `in ${days}d`;
}

interface JobRowProps {
  job: Job;
  selected: boolean;
  onSelect: (id: string, checked: boolean) => void;
  focused?: boolean;
  showScheduledAt?: boolean;
}

export function JobRow({ job, selected, onSelect, focused, showScheduledAt }: JobRowProps) {
  const navigate = useNavigate();

  const payloadStr =
    job.payload != null
      ? typeof job.payload === "string"
        ? job.payload
        : JSON.stringify(job.payload)
      : "";

  return (
    <TableRow
      className={cn("cursor-pointer", focused && "bg-muted/50")}
      data-state={selected ? "selected" : undefined}
      onClick={() => navigate(`/ui/jobs/${job.id}`)}
    >
      <TableCell onClick={(e) => e.stopPropagation()}>
        <Checkbox
          checked={selected}
          onCheckedChange={(checked) => onSelect(job.id, !!checked)}
        />
      </TableCell>
      <TableCell className="font-mono text-xs">{truncateId(job.id)}</TableCell>
      <TableCell>
        <StateBadge state={job.state} />
      </TableCell>
      <TableCell className="text-xs">
        {PRIORITY_LABELS[job.priority] || "Normal"}
      </TableCell>
      <TableCell>{job.attempt}</TableCell>
      {showScheduledAt && (
        <TableCell className="text-xs text-muted-foreground">
          {scheduledCountdown(job.scheduled_at)}
        </TableCell>
      )}
      <TableCell className="max-w-[200px] truncate font-mono text-xs text-muted-foreground">
        {truncate(payloadStr, 60)}
      </TableCell>
      <TableCell className="text-xs text-muted-foreground">
        {timeAgo(job.created_at)}
      </TableCell>
    </TableRow>
  );
}
