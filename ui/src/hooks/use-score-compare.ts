import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";

interface ScoreCompareDimension {
  mean: number;
  p50: number;
  p5: number;
  count: number;
}

interface ScoreCompareGroup {
  key: string;
  dimensions: Record<string, ScoreCompareDimension>;
}

interface ScoreCompareResponse {
  queue?: string;
  period: string;
  group_by: string;
  groups: ScoreCompareGroup[];
}

export function useScoreCompare(params: {
  queue?: string;
  period?: string;
  groupBy?: string;
}) {
  const q = new URLSearchParams();
  if (params.queue) q.set("queue", params.queue);
  if (params.period) q.set("period", params.period);
  if (params.groupBy) q.set("group_by", params.groupBy);
  const path = `/scores/compare${q.toString() ? `?${q.toString()}` : ""}`;

  return useQuery({
    queryKey: ["score-compare", params.queue || "", params.period || "", params.groupBy || ""],
    queryFn: () => api<ScoreCompareResponse>(path),
    refetchInterval: 10000,
  });
}
