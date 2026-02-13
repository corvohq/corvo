import { Progress } from "@/components/ui/progress";

interface JobProgressProps {
  current?: number;
  total?: number;
  message?: string;
}

export function JobProgress({ current, total, message }: JobProgressProps) {
  if (current == null || total == null || total === 0) return null;
  const pct = Math.min(100, Math.round((current / total) * 100));
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-sm">
        <span className="text-muted-foreground">{message || "Progress"}</span>
        <span className="font-mono text-xs">
          {current}/{total} ({pct}%)
        </span>
      </div>
      <Progress value={pct} />
    </div>
  );
}
