import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError } from "@/lib/api";

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

export default function AuditLogs() {
  const [principal, setPrincipal] = useState("");
  const [method, setMethod] = useState("");

  const params = new URLSearchParams({ limit: "100" });
  if (principal) params.set("principal", principal);
  if (method) params.set("method", method);

  const { data, isLoading, error } = useQuery({
    queryKey: ["audit-logs", principal, method],
    queryFn: () =>
      api<{ audit_logs: AuditLog[] }>(`/audit-logs?${params.toString()}`),
  });

  const logs = data?.audit_logs ?? [];

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
          onChange={(e) => setPrincipal(e.target.value)}
          className="rounded-lg border border-border bg-card px-3 py-1.5 text-sm text-foreground placeholder:text-muted-foreground"
        />
        <input
          type="text"
          placeholder="Filter by method..."
          value={method}
          onChange={(e) => setMethod(e.target.value)}
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
      )}
    </div>
  );
}
