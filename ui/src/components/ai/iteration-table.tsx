import { useState } from "react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ChevronDown, ChevronRight } from "lucide-react";
import { IterationDetail } from "./iteration-detail";

interface Iteration {
  index: number;
  model?: string;
  action?: string;
  cost?: number;
  duration_ms?: number;
  request?: unknown;
  response?: unknown;
  tool_calls?: unknown[];
}

interface IterationTableProps {
  iterations: Iteration[];
}

export function IterationTable({ iterations }: IterationTableProps) {
  const [expandedIdx, setExpandedIdx] = useState<number | null>(null);

  if (iterations.length === 0) {
    return (
      <p className="py-4 text-center text-sm text-muted-foreground">
        No iterations recorded
      </p>
    );
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="w-[40px]"></TableHead>
          <TableHead>#</TableHead>
          <TableHead>Model</TableHead>
          <TableHead>Action</TableHead>
          <TableHead className="text-right">Cost</TableHead>
          <TableHead className="text-right">Duration</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {iterations.map((iter) => (
          <>
            <TableRow
              key={iter.index}
              className="cursor-pointer"
              onClick={() =>
                setExpandedIdx(expandedIdx === iter.index ? null : iter.index)
              }
            >
              <TableCell>
                {expandedIdx === iter.index ? (
                  <ChevronDown className="h-4 w-4" />
                ) : (
                  <ChevronRight className="h-4 w-4" />
                )}
              </TableCell>
              <TableCell>{iter.index}</TableCell>
              <TableCell className="font-mono text-xs">
                {iter.model || "-"}
              </TableCell>
              <TableCell className="text-xs">{iter.action || "-"}</TableCell>
              <TableCell className="text-right font-mono text-xs">
                {iter.cost != null ? `$${iter.cost.toFixed(4)}` : "-"}
              </TableCell>
              <TableCell className="text-right text-xs">
                {iter.duration_ms != null ? `${iter.duration_ms}ms` : "-"}
              </TableCell>
            </TableRow>
            {expandedIdx === iter.index && (
              <TableRow key={`${iter.index}-detail`}>
                <TableCell colSpan={6} className="p-0">
                  <IterationDetail iteration={iter} />
                </TableCell>
              </TableRow>
            )}
          </>
        ))}
      </TableBody>
    </Table>
  );
}
