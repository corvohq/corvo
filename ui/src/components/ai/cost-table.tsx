import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

interface CostByQueue {
  queue: string;
  cost: number;
  jobs: number;
}

interface CostByModel {
  model: string;
  cost: number;
  input_tokens: number;
  output_tokens: number;
}

export function CostByQueueTable({ data }: { data: CostByQueue[] }) {
  if (data.length === 0) {
    return (
      <p className="py-8 text-center text-sm text-muted-foreground">
        No cost data by queue
      </p>
    );
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Queue</TableHead>
          <TableHead className="text-right">Cost</TableHead>
          <TableHead className="text-right">Jobs</TableHead>
          <TableHead className="text-right">$/Job</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {data.map((row) => (
          <TableRow key={row.queue}>
            <TableCell className="font-medium">{row.queue}</TableCell>
            <TableCell className="text-right font-mono">
              ${row.cost.toFixed(4)}
            </TableCell>
            <TableCell className="text-right">{row.jobs}</TableCell>
            <TableCell className="text-right font-mono">
              ${row.jobs > 0 ? (row.cost / row.jobs).toFixed(4) : "0"}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

export function CostByModelTable({ data }: { data: CostByModel[] }) {
  if (data.length === 0) {
    return (
      <p className="py-8 text-center text-sm text-muted-foreground">
        No cost data by model
      </p>
    );
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Model</TableHead>
          <TableHead className="text-right">Cost</TableHead>
          <TableHead className="text-right">Input Tokens</TableHead>
          <TableHead className="text-right">Output Tokens</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {data.map((row) => (
          <TableRow key={row.model}>
            <TableCell className="font-medium">{row.model}</TableCell>
            <TableCell className="text-right font-mono">
              ${row.cost.toFixed(4)}
            </TableCell>
            <TableCell className="text-right font-mono">
              {row.input_tokens.toLocaleString()}
            </TableCell>
            <TableCell className="text-right font-mono">
              {row.output_tokens.toLocaleString()}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
