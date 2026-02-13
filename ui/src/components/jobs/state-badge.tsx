import { Badge } from "@/components/ui/badge";
import { STATE_COLORS } from "@/lib/constants";
import { cn } from "@/lib/utils";

export function StateBadge({ state }: { state: string }) {
  return (
    <Badge
      variant="secondary"
      className={cn("capitalize", STATE_COLORS[state])}
    >
      {state}
    </Badge>
  );
}
