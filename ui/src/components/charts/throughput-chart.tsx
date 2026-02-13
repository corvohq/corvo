import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useThroughput } from "@/hooks/use-throughput";

export function ThroughputChart() {
  const { data, isLoading } = useThroughput();

  if (isLoading || !data) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="text-sm">Throughput (last 60 min)</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex h-[250px] items-center justify-center text-sm text-muted-foreground">
            Loading...
          </div>
        </CardContent>
      </Card>
    );
  }

  const chartData = data.map((b) => ({
    time: new Date(b.minute).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    }),
    Enqueued: b.enqueued,
    Completed: b.completed,
    Failed: b.failed,
  }));

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm">Throughput (last 60 min)</CardTitle>
      </CardHeader>
      <CardContent>
        <ResponsiveContainer width="100%" height={250}>
          <AreaChart data={chartData}>
            <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
            <XAxis
              dataKey="time"
              tick={{ fontSize: 11 }}
              interval="preserveStartEnd"
            />
            <YAxis tick={{ fontSize: 11 }} allowDecimals={false} />
            <Tooltip />
            <Legend />
            <Area
              type="monotone"
              dataKey="Enqueued"
              stackId="1"
              stroke="#3b82f6"
              fill="#3b82f6"
              fillOpacity={0.3}
            />
            <Area
              type="monotone"
              dataKey="Completed"
              stackId="1"
              stroke="#22c55e"
              fill="#22c55e"
              fillOpacity={0.3}
            />
            <Area
              type="monotone"
              dataKey="Failed"
              stackId="1"
              stroke="#ef4444"
              fill="#ef4444"
              fillOpacity={0.3}
            />
          </AreaChart>
        </ResponsiveContainer>
      </CardContent>
    </Card>
  );
}
