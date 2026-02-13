import { useState, useCallback } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { SearchPanel } from "@/components/search/search-panel";
import { JobTable } from "@/components/jobs/job-table";
import { BulkBar } from "@/components/bulk/bulk-bar";
import { useSearch } from "@/hooks/use-search";
import type { SearchFilter } from "@/lib/types";

const defaultFilter: SearchFilter = {
  state: ["dead"],
  limit: 50,
  sort: "created_at",
  order: "desc",
};

export default function DeadLetter() {
  const [filter, setFilter] = useState<SearchFilter>(defaultFilter);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());

  const { data: searchResult, isLoading } = useSearch(filter);

  const handleFilterChange = useCallback((f: SearchFilter) => {
    setFilter({ ...f, state: ["dead"], cursor: undefined });
  }, []);

  const handleReset = useCallback(() => {
    setFilter(defaultFilter);
  }, []);

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
      setFilter((f) => ({ ...f, cursor: searchResult.cursor }));
    }
  }, [searchResult]);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Dead Letter Queue</h1>
      <p className="text-sm text-muted-foreground">
        Jobs that have exhausted all retry attempts across all queues.
      </p>

      <SearchPanel
        filter={filter}
        onFilterChange={handleFilterChange}
        onReset={handleReset}
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-sm">
            Dead Jobs
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
          />
        </CardContent>
      </Card>

      <BulkBar
        selectedIds={Array.from(selectedIds)}
        onClear={() => setSelectedIds(new Set())}
      />
    </div>
  );
}
