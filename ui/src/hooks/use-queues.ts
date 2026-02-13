import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { QueueInfo } from "@/lib/types";

export function useQueues() {
  return useQuery({
    queryKey: ["queues"],
    queryFn: () => api<QueueInfo[]>("/queues"),
    refetchInterval: 3000,
  });
}
