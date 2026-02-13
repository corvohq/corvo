import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { UsageSummaryResponse } from "@/lib/types";

export function useUsageSummary(period: string, groupBy?: string) {
  const params = new URLSearchParams();
  if (period) params.set("period", period);
  if (groupBy) params.set("group_by", groupBy);
  const path = `/usage/summary${params.toString() ? `?${params.toString()}` : ""}`;

  return useQuery({
    queryKey: ["usage-summary", period, groupBy || ""],
    queryFn: () => api<UsageSummaryResponse>(path),
    refetchInterval: 10000,
  });
}
