import { useState, useCallback, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { Checkbox } from "@/components/ui/checkbox";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { JobRow } from "./job-row";
import { useHotkeys } from "@/hooks/use-hotkeys";
import type { Job } from "@/lib/types";

interface JobTableProps {
  jobs: Job[];
  selectedIds: Set<string>;
  onSelect: (id: string, checked: boolean) => void;
  onSelectAll: (checked: boolean) => void;
  hasMore?: boolean;
  onLoadMore?: () => void;
  loading?: boolean;
  showScheduledAt?: boolean;
}

export function JobTable({
  jobs,
  selectedIds,
  onSelect,
  onSelectAll,
  hasMore,
  onLoadMore,
  loading,
  showScheduledAt,
}: JobTableProps) {
  const allSelected = jobs.length > 0 && jobs.every((j) => selectedIds.has(j.id));
  const [focusedIndex, setFocusedIndex] = useState(-1);
  const navigate = useNavigate();
  const tableRef = useRef<HTMLDivElement>(null);

  // Reset focus when jobs change
  useEffect(() => {
    setFocusedIndex(-1);
  }, [jobs]);

  const hotkeyMap = useCallback(() => ({
    j: () => {
      setFocusedIndex((prev) => Math.min(prev + 1, jobs.length - 1));
    },
    k: () => {
      setFocusedIndex((prev) => Math.max(prev - 1, 0));
    },
    Enter: () => {
      if (focusedIndex >= 0 && focusedIndex < jobs.length) {
        navigate(`/ui/jobs/${jobs[focusedIndex].id}`);
      }
    },
  }), [jobs, focusedIndex, navigate]);

  useHotkeys(hotkeyMap());

  return (
    <div ref={tableRef}>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-[40px]">
              <Checkbox
                checked={allSelected}
                onCheckedChange={(checked) => onSelectAll(!!checked)}
              />
            </TableHead>
            <TableHead>Job ID</TableHead>
            <TableHead>State</TableHead>
            <TableHead>Priority</TableHead>
            <TableHead>Attempt</TableHead>
            {showScheduledAt && <TableHead>Runs In</TableHead>}
            <TableHead>Payload</TableHead>
            <TableHead>Created</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {jobs.map((job, i) => (
            <JobRow
              key={job.id}
              job={job}
              selected={selectedIds.has(job.id)}
              onSelect={onSelect}
              focused={i === focusedIndex}
              showScheduledAt={showScheduledAt}
            />
          ))}
        </TableBody>
      </Table>

      {jobs.length === 0 && !loading && (
        <div className="py-12 text-center text-sm text-muted-foreground">
          No jobs found
        </div>
      )}

      {loading && (
        <div className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </div>
      )}

      {hasMore && (
        <div className="flex justify-center border-t p-4">
          <Button variant="outline" size="sm" onClick={onLoadMore}>
            Load More
          </Button>
        </div>
      )}
    </div>
  );
}
