import { useCallback } from "react";
import { useSearchParams } from "react-router-dom";
import type { SearchFilter } from "@/lib/types";

const ARRAY_KEYS = ["state"] as const;
const STRING_KEYS = [
  "queue",
  "priority",
  "payload_contains",
  "error_contains",
  "job_id_prefix",
  "batch_id",
  "worker_id",
  "unique_key",
  "created_after",
  "created_before",
  "sort",
  "order",
] as const;

function paramsToFilter(params: URLSearchParams, defaults: SearchFilter): SearchFilter {
  const filter: SearchFilter = { ...defaults };

  const stateParam = params.get("state");
  if (stateParam) {
    filter.state = stateParam.split(",");
  }

  for (const key of STRING_KEYS) {
    const val = params.get(key);
    if (val) {
      (filter as Record<string, unknown>)[key] = val;
    }
  }

  return filter;
}

function filterToParams(filter: SearchFilter, defaults: SearchFilter): URLSearchParams {
  const params = new URLSearchParams();

  if (filter.state && JSON.stringify(filter.state) !== JSON.stringify(defaults.state)) {
    params.set("state", filter.state.join(","));
  }

  for (const key of STRING_KEYS) {
    const val = (filter as Record<string, unknown>)[key] as string | undefined;
    const def = (defaults as Record<string, unknown>)[key] as string | undefined;
    if (val && val !== def) {
      params.set(key, val);
    }
  }

  return params;
}

export function useFilterParams(
  defaults: SearchFilter,
): [SearchFilter, (f: SearchFilter) => void, () => void] {
  const [searchParams, setSearchParams] = useSearchParams();

  const filter = paramsToFilter(searchParams, defaults);

  const setFilter = useCallback(
    (f: SearchFilter) => {
      const params = filterToParams(f, defaults);
      setSearchParams(params, { replace: true });
    },
    [defaults, setSearchParams],
  );

  const resetFilter = useCallback(() => {
    setSearchParams({}, { replace: true });
  }, [setSearchParams]);

  return [filter, setFilter, resetFilter];
}
