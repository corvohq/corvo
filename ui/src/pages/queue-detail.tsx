import { useState, useCallback } from "react";
import { useParams } from "react-router-dom";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SearchPanel } from "@/components/search/search-panel";
import { JobTable } from "@/components/jobs/job-table";
import { BulkBar } from "@/components/bulk/bulk-bar";
import { QueueActions } from "@/components/queues/queue-actions";
import { useQueues } from "@/hooks/use-queues";
import { useSearch } from "@/hooks/use-search";
import { useFilterParams } from "@/hooks/use-filter-params";
import { exportJSON, exportCSV } from "@/lib/export";
import { formatNumber } from "@/lib/utils";
import type { SearchFilter } from "@/lib/types";
import { Download } from "lucide-react";

const defaultFilter: SearchFilter = {
  limit: 50,
  sort: "created_at",
  order: "desc",
};

export default function QueueDetail() {
  const { name } = useParams<{ name: string }>();
  const { data: queues } = useQueues();
  const queue = queues?.find((q) => q.name === name);

  const [filter, setFilter, resetFilter] = useFilterParams({
    ...defaultFilter,
    queue: name,
  });
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());

  const activeFilter = { ...filter, queue: name };
  const { data: searchResult, isLoading } = useSearch(activeFilter);

  const handleFilterChange = useCallback(
    (f: SearchFilter) => {
      setFilter({ ...f, queue: name, cursor: undefined });
    },
    [name, setFilter],
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
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold">{name}</h1>
          {queue && (
            <div className="mt-2 flex items-center gap-4">
              <Badge
                variant="secondary"
                className={
                  queue.paused
                    ? ""
                    : "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                }
              >
                {queue.paused ? "Paused" : "Active"}
              </Badge>
              <div className="flex gap-3 text-sm text-muted-foreground">
                <span>Pending: {formatNumber(queue.pending)}</span>
                <span>Active: {formatNumber(queue.active)}</span>
                <span>Dead: {formatNumber(queue.dead)}</span>
                <span>Completed: {formatNumber(queue.completed)}</span>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Queue actions */}
      {queue && <QueueActions queue={queue} />}

      {/* Search */}
      <SearchPanel
        filter={activeFilter}
        onFilterChange={handleFilterChange}
        onReset={handleReset}
      />

      {/* Results */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="text-sm">
              Jobs
              {searchResult && (
                <span className="ml-2 font-normal text-muted-foreground">
                  ({searchResult.total} total)
                </span>
              )}
            </CardTitle>
            {searchResult?.jobs && searchResult.jobs.length > 0 && (
              <div className="flex gap-1">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() =>
                    exportJSON(searchResult.jobs, `${name}-jobs.json`)
                  }
                >
                  <Download className="mr-1 h-3 w-3" /> JSON
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() =>
                    exportCSV(searchResult.jobs, `${name}-jobs.csv`)
                  }
                >
                  <Download className="mr-1 h-3 w-3" /> CSV
                </Button>
              </div>
            )}
          </div>
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

      {/* Bulk bar */}
      <BulkBar
        selectedIds={Array.from(selectedIds)}
        onClear={() => setSelectedIds(new Set())}
      />
    </div>
  );
}
