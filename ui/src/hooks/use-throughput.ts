import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";

export interface ThroughputBucket {
  minute: string;
  enqueued: number;
  completed: number;
  failed: number;
}

export function useThroughput() {
  return useQuery({
    queryKey: ["throughput"],
    queryFn: () => api<ThroughputBucket[]>("/metrics/throughput"),
    refetchInterval: 10_000,
  });
}
