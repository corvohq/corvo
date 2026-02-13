import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { JobIteration } from "@/lib/types";

interface IterationsResponse {
  iterations: JobIteration[];
}

export function useJobIterations(id: string) {
  return useQuery({
    queryKey: ["job-iterations", id],
    queryFn: async () => {
      const res = await api<IterationsResponse>(`/jobs/${id}/iterations`);
      return res.iterations || [];
    },
    enabled: !!id,
    refetchInterval: 5000,
  });
}
