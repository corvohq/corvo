import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight } from "lucide-react";

interface AuditLog {
  id: number;
  namespace: string;
  principal: string | null;
  role: string | null;
  method: string;
  path: string;
  status_code: number;
  metadata?: { duration_ms?: number; query?: string };
  created_at: string;
}

interface AuditResponse {
  audit_logs: AuditLog[];
  total: number;
  limit: number;
  offset: number;
}

const PAGE_SIZE = 50;

export default function AuditLogs() {
  const [principal, setPrincipal] = useState("");
  const [method, setMethod] = useState("");
  const [offset, setOffset] = useState(0);

  const params = new URLSearchParams({
    limit: String(PAGE_SIZE),
    offset: String(offset),
  });
  if (principal) params.set("principal", principal);
  if (method) params.set("method", method);

  const { data, isLoading, error } = useQuery({
    queryKey: ["audit-logs", principal, method, offset],
    queryFn: () => api<AuditResponse>(`/audit-logs?${params.toString()}`),
  });

  const logs = data?.audit_logs ?? [];
  const total = data?.total ?? 0;
  const page = Math.floor(offset / PAGE_SIZE) + 1;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const hasPrev = offset > 0;
  const hasNext = offset + PAGE_SIZE < total;

  const resetPage = () => setOffset(0);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Audit Logs</h1>
        <p className="text-sm text-muted-foreground">
          Record of write operations performed against this instance.
        </p>
      </div>

      <div className="flex gap-3">
        <input
          type="text"
          placeholder="Filter by principal..."
          value={principal}
          onChange={(e) => { setPrincipal(e.target.value); resetPage(); }}
          className="rounded-lg border border-border bg-card px-3 py-1.5 text-sm text-foreground placeholder:text-muted-foreground"
        />
        <input
          type="text"
          placeholder="Filter by method..."
          value={method}
          onChange={(e) => { setMethod(e.target.value); resetPage(); }}
          className="rounded-lg border border-border bg-card px-3 py-1.5 text-sm text-foreground placeholder:text-muted-foreground"
        />
      </div>

      {error instanceof ApiError && error.status === 403 && (
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-6 text-center">
          <p className="text-sm text-yellow-400">
            Audit logs require an enterprise license.
          </p>
        </div>
      )}

      {error && !(error instanceof ApiError && error.status === 403) && (
        <div className="rounded-lg border border-red-500/30 bg-red-500/5 p-6 text-center">
          <p className="text-sm text-red-400">
            Failed to load audit logs: {error.message}
          </p>
        </div>
      )}

      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {!isLoading && logs.length === 0 && (
        <div className="rounded-lg border border-dashed p-12 text-center">
          <p className="text-sm text-muted-foreground">
            No audit logs found. Write operations will be recorded here.
          </p>
        </div>
      )}

      {logs.length > 0 && (
        <>
          <div className="overflow-x-auto rounded-lg border border-border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/50">
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Time</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Principal</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Role</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Method</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Path</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Status</th>
                  <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Duration</th>
                </tr>
              </thead>
              <tbody>
                {logs.map((log) => (
                  <tr key={log.id} className="border-b border-border/50 hover:bg-muted/30">
                    <td className="px-4 py-2 text-foreground whitespace-nowrap">
                      {new Date(log.created_at).toLocaleString()}
                    </td>
                    <td className="px-4 py-2 text-foreground">{log.principal ?? "—"}</td>
                    <td className="px-4 py-2 text-foreground">{log.role ?? "—"}</td>
                    <td className="px-4 py-2">
                      <span className="rounded bg-muted px-1.5 py-0.5 text-xs font-mono">
                        {log.method}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-foreground font-mono text-xs">{log.path}</td>
                    <td className="px-4 py-2">
                      <span
                        className={
                          log.status_code < 400
                            ? "text-green-400"
                            : log.status_code < 500
                              ? "text-yellow-400"
                              : "text-red-400"
                        }
                      >
                        {log.status_code}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-muted-foreground text-xs">
                      {log.metadata?.duration_ms != null
                        ? `${log.metadata.duration_ms}ms`
                        : "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex items-center justify-between">
            <p className="text-sm text-muted-foreground">
              {total.toLocaleString()} total entries
            </p>
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="sm"
                disabled={!hasPrev}
                onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}
              >
                <ChevronLeft className="mr-1 h-3 w-3" /> Prev
              </Button>
              <span className="text-sm text-muted-foreground">
                Page {page} of {totalPages}
              </span>
              <Button
                variant="outline"
                size="sm"
                disabled={!hasNext}
                onClick={() => setOffset(offset + PAGE_SIZE)}
              >
                Next <ChevronRight className="ml-1 h-3 w-3" />
              </Button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
