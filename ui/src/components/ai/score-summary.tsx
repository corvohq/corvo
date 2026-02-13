import { Badge } from "@/components/ui/badge";

interface ScoreSummaryProps {
  scores: Record<string, number>;
}

export function ScoreSummary({ scores }: ScoreSummaryProps) {
  const entries = Object.entries(scores);
  if (entries.length === 0) return null;

  return (
    <div className="flex flex-wrap gap-2">
      {entries.map(([dimension, value]) => (
        <Badge key={dimension} variant="outline" className="gap-1">
          <span className="text-muted-foreground">{dimension}:</span>
          <span className="font-mono">{value}</span>
        </Badge>
      ))}
    </div>
  );
}
