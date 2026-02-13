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
import type { JobIteration } from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Fragment } from "react";

interface IterationTableProps {
  iterations: JobIteration[];
  onReplay?: (iteration: number) => void;
  replaying?: boolean;
}

export function IterationTable({ iterations, onReplay, replaying = false }: IterationTableProps) {
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
          <TableHead>Status</TableHead>
          <TableHead className="text-right">Cost</TableHead>
          <TableHead className="text-right">Tokens</TableHead>
          {onReplay && <TableHead className="text-right">Replay</TableHead>}
        </TableRow>
      </TableHeader>
      <TableBody>
        {iterations.map((iter) => (
          <Fragment key={iter.id}>
            <TableRow
              className="cursor-pointer"
              onClick={() =>
                setExpandedIdx(expandedIdx === iter.iteration ? null : iter.iteration)
              }
            >
              <TableCell>
                {expandedIdx === iter.iteration ? (
                  <ChevronDown className="h-4 w-4" />
                ) : (
                  <ChevronRight className="h-4 w-4" />
                )}
              </TableCell>
              <TableCell>{iter.iteration}</TableCell>
              <TableCell className="font-mono text-xs">
                {iter.model || iter.provider || "-"}
              </TableCell>
              <TableCell className="text-xs">{iter.status || "-"}</TableCell>
              <TableCell className="text-right font-mono text-xs">
                {iter.cost_usd != null ? `$${iter.cost_usd.toFixed(4)}` : "-"}
              </TableCell>
              <TableCell className="text-right text-xs">
                {((iter.input_tokens || 0) + (iter.output_tokens || 0)).toLocaleString()}
              </TableCell>
              {onReplay && (
                <TableCell className="text-right">
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={replaying}
                    onClick={(e) => {
                      e.stopPropagation();
                      onReplay(iter.iteration);
                    }}
                  >
                    Replay
                  </Button>
                </TableCell>
              )}
            </TableRow>
            {expandedIdx === iter.iteration && (
              <TableRow>
                <TableCell colSpan={onReplay ? 7 : 6} className="p-0">
                  <IterationDetail iteration={iter} />
                </TableCell>
              </TableRow>
            )}
          </Fragment>
        ))}
      </TableBody>
    </Table>
  );
}
