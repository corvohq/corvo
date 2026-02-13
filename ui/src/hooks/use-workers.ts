import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { Worker } from "@/lib/types";

export function useWorkers() {
  return useQuery({
    queryKey: ["workers"],
    queryFn: () => api<Worker[]>("/workers"),
    refetchInterval: 5000,
  });
}
