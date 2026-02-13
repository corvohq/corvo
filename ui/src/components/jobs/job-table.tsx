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
import type { Job } from "@/lib/types";

interface JobTableProps {
  jobs: Job[];
  selectedIds: Set<string>;
  onSelect: (id: string, checked: boolean) => void;
  onSelectAll: (checked: boolean) => void;
  hasMore?: boolean;
  onLoadMore?: () => void;
  loading?: boolean;
}

export function JobTable({
  jobs,
  selectedIds,
  onSelect,
  onSelectAll,
  hasMore,
  onLoadMore,
  loading,
}: JobTableProps) {
  const allSelected = jobs.length > 0 && jobs.every((j) => selectedIds.has(j.id));

  return (
    <div>
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
            <TableHead>Payload</TableHead>
            <TableHead>Created</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {jobs.map((job) => (
            <JobRow
              key={job.id}
              job={job}
              selected={selectedIds.has(job.id)}
              onSelect={onSelect}
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
