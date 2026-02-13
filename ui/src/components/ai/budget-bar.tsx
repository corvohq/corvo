import { Progress } from "@/components/ui/progress";

interface BudgetBarProps {
  spent: number;
  budget: number;
  label?: string;
}

export function BudgetBar({ spent, budget, label = "Budget" }: BudgetBarProps) {
  if (budget <= 0) return null;
  const pct = Math.min(100, (spent / budget) * 100);
  const isWarning = pct > 80;
  const isDanger = pct > 95;

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-sm">
        <span className="text-muted-foreground">{label}</span>
        <span className="font-mono text-xs">
          ${spent.toFixed(2)} / ${budget.toFixed(2)}
        </span>
      </div>
      <Progress
        value={pct}
        className={
          isDanger
            ? "[&>div]:bg-red-500"
            : isWarning
              ? "[&>div]:bg-yellow-500"
              : ""
        }
      />
    </div>
  );
}
