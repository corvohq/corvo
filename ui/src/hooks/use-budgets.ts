import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { Budget } from "@/lib/types";

export function useBudgets() {
  return useQuery({
    queryKey: ["budgets"],
    queryFn: () => api<Budget[]>("/budgets"),
    refetchInterval: 10000,
  });
}
