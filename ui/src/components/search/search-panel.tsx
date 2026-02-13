import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { ALL_STATES } from "@/lib/constants";
import { cn } from "@/lib/utils";
import { STATE_COLORS } from "@/lib/constants";
import { ChevronDown, ChevronUp, X } from "lucide-react";
import type { SearchFilter } from "@/lib/types";

interface SearchPanelProps {
  filter: SearchFilter;
  onFilterChange: (filter: SearchFilter) => void;
  onReset: () => void;
}

export function SearchPanel({ filter, onFilterChange, onReset }: SearchPanelProps) {
  const [expanded, setExpanded] = useState(false);

  const toggleState = (state: string) => {
    const current = filter.state || [];
    const next = current.includes(state)
      ? current.filter((s) => s !== state)
      : [...current, state];
    onFilterChange({ ...filter, state: next.length > 0 ? next : undefined });
  };

  return (
    <div className="rounded-lg border p-4">
      {/* State filter chips */}
      <div className="flex flex-wrap gap-1.5">
        {ALL_STATES.map((state) => {
          const active = filter.state?.includes(state);
          return (
            <Badge
              key={state}
              variant="secondary"
              className={cn(
                "cursor-pointer capitalize transition-opacity",
                active ? STATE_COLORS[state] : "opacity-40 hover:opacity-70",
              )}
              onClick={() => toggleState(state)}
            >
              {state}
              {active && <X className="ml-1 h-3 w-3" />}
            </Badge>
          );
        })}
      </div>

      {/* Toggle advanced */}
      <button
        className="mt-3 flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
        onClick={() => setExpanded(!expanded)}
      >
        {expanded ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
        Advanced filters
      </button>

      {expanded && (
        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Priority</label>
            <select
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm"
              value={filter.priority || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, priority: e.target.value || undefined })
              }
            >
              <option value="">All</option>
              <option value="critical">Critical</option>
              <option value="high">High</option>
              <option value="normal">Normal</option>
            </select>
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Payload contains</label>
            <Input
              placeholder="Search in payload..."
              value={filter.payload_contains || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, payload_contains: e.target.value || undefined })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Error contains</label>
            <Input
              placeholder="Search in errors..."
              value={filter.error_contains || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, error_contains: e.target.value || undefined })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Job ID prefix</label>
            <Input
              placeholder="Job ID prefix..."
              value={filter.job_id_prefix || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, job_id_prefix: e.target.value || undefined })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Batch ID</label>
            <Input
              placeholder="Batch ID..."
              value={filter.batch_id || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, batch_id: e.target.value || undefined })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Worker ID</label>
            <Input
              placeholder="Worker ID..."
              value={filter.worker_id || ""}
              onChange={(e) =>
                onFilterChange({ ...filter, worker_id: e.target.value || undefined })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Created after</label>
            <input
              type="datetime-local"
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm"
              value={filter.created_after ? filter.created_after.slice(0, 16) : ""}
              onChange={(e) =>
                onFilterChange({
                  ...filter,
                  created_after: e.target.value ? new Date(e.target.value).toISOString() : undefined,
                })
              }
            />
          </div>

          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Created before</label>
            <input
              type="datetime-local"
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm"
              value={filter.created_before ? filter.created_before.slice(0, 16) : ""}
              onChange={(e) =>
                onFilterChange({
                  ...filter,
                  created_before: e.target.value ? new Date(e.target.value).toISOString() : undefined,
                })
              }
            />
          </div>
        </div>
      )}

      {/* Actions */}
      <div className="mt-3 flex gap-2">
        <Button variant="outline" size="sm" onClick={onReset}>
          Reset
        </Button>
      </div>
    </div>
  );
}
