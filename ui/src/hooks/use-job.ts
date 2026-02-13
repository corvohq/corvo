import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { Job } from "@/lib/types";

export function useJob(id: string) {
  return useQuery({
    queryKey: ["job", id],
    queryFn: () => api<Job>(`/jobs/${id}`),
    enabled: !!id,
    refetchInterval: 5000,
  });
}
