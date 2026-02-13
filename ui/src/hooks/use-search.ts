import { useQuery } from "@tanstack/react-query";
import { post } from "@/lib/api";
import type { SearchFilter, SearchResult } from "@/lib/types";

export function useSearch(filter: SearchFilter, enabled = true) {
  return useQuery({
    queryKey: ["search", filter],
    queryFn: () => post<SearchResult>("/jobs/search", filter),
    enabled,
    refetchInterval: 5000,
  });
}
