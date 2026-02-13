import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CostChart } from "@/components/ai/cost-chart";
import { CostByQueueTable, CostByModelTable } from "@/components/ai/cost-table";
import { BudgetBar } from "@/components/ai/budget-bar";

export default function CostDashboard() {
  const [_period, setPeriod] = useState("7d");

  // These endpoints don't exist yet — show empty states
  const costData: { date: string; cost: number }[] = [];
  const costByQueue: { queue: string; cost: number; jobs: number }[] = [];
  const costByModel: {
    model: string;
    cost: number;
    input_tokens: number;
    output_tokens: number;
  }[] = [];

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">AI Cost Dashboard</h1>
          <p className="text-sm text-muted-foreground">
            Track LLM usage, costs, and budgets across queues.
          </p>
        </div>
        <select
          className="rounded-md border border-input bg-transparent px-3 py-1.5 text-sm"
          value={_period}
          onChange={(e) => setPeriod(e.target.value)}
        >
          <option value="24h">Last 24h</option>
          <option value="7d">Last 7 days</option>
          <option value="30d">Last 30 days</option>
        </select>
      </div>

      {/* Summary */}
      <div className="grid gap-4 sm:grid-cols-3">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm text-muted-foreground">
              Total Spend
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">$0.00</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm text-muted-foreground">
              Budget
            </CardTitle>
          </CardHeader>
          <CardContent>
            <BudgetBar spent={0} budget={0} />
            <p className="mt-2 text-xs text-muted-foreground">
              No budget configured
            </p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm text-muted-foreground">
              Cache Hit Rate
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">-</p>
          </CardContent>
        </Card>
      </div>

      {/* Chart */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Spend Over Time</CardTitle>
        </CardHeader>
        <CardContent>
          <CostChart data={costData} />
        </CardContent>
      </Card>

      {/* Tables */}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Cost by Queue</CardTitle>
          </CardHeader>
          <CardContent>
            <CostByQueueTable data={costByQueue} />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">Cost by Model</CardTitle>
          </CardHeader>
          <CardContent>
            <CostByModelTable data={costByModel} />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
