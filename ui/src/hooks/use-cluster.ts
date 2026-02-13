import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { ClusterStatus } from "@/lib/types";

export function useCluster() {
  return useQuery({
    queryKey: ["cluster"],
    queryFn: () => api<ClusterStatus>("/cluster/status"),
    refetchInterval: 5000,
  });
}
