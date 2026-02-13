import { useState, useCallback } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { SearchPanel } from "@/components/search/search-panel";
import { JobTable } from "@/components/jobs/job-table";
import { BulkBar } from "@/components/bulk/bulk-bar";
import { useSearch } from "@/hooks/use-search";
import { useFilterParams } from "@/hooks/use-filter-params";
import type { SearchFilter } from "@/lib/types";

const defaultFilter: SearchFilter = {
  state: ["scheduled"],
  limit: 50,
  sort: "created_at",
  order: "desc",
};

export default function ScheduledJobs() {
  const [filter, setFilter, resetFilter] = useFilterParams(defaultFilter);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());

  const activeFilter = { ...filter, state: ["scheduled"] as string[] };
  const { data: searchResult, isLoading } = useSearch(activeFilter);

  const handleFilterChange = useCallback(
    (f: SearchFilter) => {
      setFilter({ ...f, state: ["scheduled"], cursor: undefined });
    },
    [setFilter],
  );

  const handleReset = useCallback(() => {
    resetFilter();
  }, [resetFilter]);

  const handleSelect = useCallback((id: string, checked: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (checked) next.add(id);
      else next.delete(id);
      return next;
    });
  }, []);

  const handleSelectAll = useCallback(
    (checked: boolean) => {
      if (checked && searchResult?.jobs) {
        setSelectedIds(new Set(searchResult.jobs.map((j) => j.id)));
      } else {
        setSelectedIds(new Set());
      }
    },
    [searchResult],
  );

  const handleLoadMore = useCallback(() => {
    if (searchResult?.cursor) {
      setFilter({ ...filter, cursor: searchResult.cursor });
    }
  }, [searchResult, filter, setFilter]);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Scheduled Jobs</h1>
      <p className="text-sm text-muted-foreground">
        Jobs scheduled to run at a future time. Use "Run Now" to promote them immediately.
      </p>

      <SearchPanel
        filter={activeFilter}
        onFilterChange={handleFilterChange}
        onReset={handleReset}
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            Scheduled Jobs
            {searchResult && (
              <span className="ml-2 font-normal text-muted-foreground">
                ({searchResult.total} total)
              </span>
            )}
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <JobTable
            jobs={searchResult?.jobs || []}
            selectedIds={selectedIds}
            onSelect={handleSelect}
            onSelectAll={handleSelectAll}
            hasMore={searchResult?.has_more}
            onLoadMore={handleLoadMore}
            loading={isLoading}
            showScheduledAt
          />
        </CardContent>
      </Card>

      <BulkBar
        selectedIds={Array.from(selectedIds)}
        onClear={() => setSelectedIds(new Set())}
        showRunNow
      />
    </div>
  );
}
