import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CostChart } from "@/components/ai/cost-chart";
import { CostByQueueTable, CostByModelTable } from "@/components/ai/cost-table";
import { BudgetBar } from "@/components/ai/budget-bar";
import { useUsageSummary } from "@/hooks/use-usage";
import { useBudgets } from "@/hooks/use-budgets";

export default function CostDashboard() {
  const [period, setPeriod] = useState("7d");
  const summary = useUsageSummary(period);
  const summaryByQueue = useUsageSummary(period, "queue");
  const summaryByModel = useUsageSummary(period, "model");
  const dailySummary = useUsageSummary("24h");
  const budgets = useBudgets();

  const queueGroups = summaryByQueue.data?.groups || [];
  const modelGroups = summaryByModel.data?.groups || [];

  const costData: { date: string; cost: number }[] =
    summary.data?.totals?.cost_usd && summary.data.totals.cost_usd > 0
      ? [{ date: summary.data.period, cost: summary.data.totals.cost_usd }]
      : [];

  const costByQueue = queueGroups.map((g) => ({
    queue: g.key || "(unknown)",
    cost: g.cost_usd,
    jobs: g.count,
  }));
  const costByModel = modelGroups.map((g) => ({
    model: g.key || "(unknown)",
    cost: g.cost_usd,
    input_tokens: g.input_tokens,
    output_tokens: g.output_tokens,
  }));

  const globalDailyBudget = (budgets.data || []).find(
    (b) => b.scope === "global" && b.target === "*" && b.daily_usd != null,
  );
  const totalSpend = summary.data?.totals?.cost_usd || 0;
  const spent24h = dailySummary.data?.totals?.cost_usd || 0;
  const cacheCreate = summary.data?.totals?.cache_creation_tokens || 0;
  const cacheRead = summary.data?.totals?.cache_read_tokens || 0;
  const cacheHitRate = cacheCreate + cacheRead > 0 ? (cacheRead / (cacheCreate + cacheRead)) * 100 : 0;
  const isLoading =
    summary.isLoading || summaryByQueue.isLoading || summaryByModel.isLoading || budgets.isLoading || dailySummary.isLoading;

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
          value={period}
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
            <p className="text-2xl font-bold">
              {isLoading ? "..." : `$${totalSpend.toFixed(4)}`}
            </p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm text-muted-foreground">
              Budget
            </CardTitle>
          </CardHeader>
          <CardContent>
            <BudgetBar
              spent={spent24h}
              budget={globalDailyBudget?.daily_usd || 0}
              label="Global Daily Budget"
            />
            {!globalDailyBudget && (
              <p className="mt-2 text-xs text-muted-foreground">
                No global daily budget configured
              </p>
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm text-muted-foreground">
              Cache Hit Rate
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-2xl font-bold">
              {isLoading ? "..." : `${cacheHitRate.toFixed(1)}%`}
            </p>
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
