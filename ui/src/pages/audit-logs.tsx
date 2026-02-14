import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";

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

  const { data, isLoading } = useQuery({
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
          className="rounded-lg border border-surface-700 bg-surface-900 px-3 py-1.5 text-sm text-surface-300 placeholder:text-surface-500"
        />
        <input
          type="text"
          placeholder="Filter by method..."
          value={method}
          onChange={(e) => setMethod(e.target.value)}
          className="rounded-lg border border-surface-700 bg-surface-900 px-3 py-1.5 text-sm text-surface-300 placeholder:text-surface-500"
        />
      </div>

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
        <div className="overflow-x-auto rounded-lg border border-surface-800">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-surface-800 bg-surface-900/50">
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Time</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Principal</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Role</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Method</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Path</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Status</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Duration</th>
              </tr>
            </thead>
            <tbody>
              {logs.map((log) => (
                <tr key={log.id} className="border-b border-surface-800/50 hover:bg-surface-900/30">
                  <td className="px-4 py-2 text-surface-300 whitespace-nowrap">
                    {new Date(log.created_at).toLocaleString()}
                  </td>
                  <td className="px-4 py-2 text-surface-300">{log.principal ?? "—"}</td>
                  <td className="px-4 py-2 text-surface-300">{log.role ?? "—"}</td>
                  <td className="px-4 py-2">
                    <span className="rounded bg-surface-800 px-1.5 py-0.5 text-xs font-mono">
                      {log.method}
                    </span>
                  </td>
                  <td className="px-4 py-2 text-surface-300 font-mono text-xs">{log.path}</td>
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
                  <td className="px-4 py-2 text-surface-400 text-xs">
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
