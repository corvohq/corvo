import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post, del } from "@/lib/api";

interface Namespace {
  name: string;
  created_at: string;
}

export default function NamespacesPage() {
  const qc = useQueryClient();
  const { data: namespaces = [], isLoading } = useQuery({
    queryKey: ["namespaces"],
    queryFn: () => api<Namespace[]>("/namespaces"),
  });

  const [newName, setNewName] = useState("");

  const createMutation = useMutation({
    mutationFn: (name: string) => post("/namespaces", { name }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["namespaces"] });
      setNewName("");
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (name: string) => del(`/namespaces/${name}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["namespaces"] }),
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">Namespaces</h1>
        <p className="text-sm text-muted-foreground">
          Manage tenant namespaces for workload isolation.
        </p>
      </div>

      <div className="flex items-center gap-2">
        <input
          type="text"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          placeholder="Namespace name (e.g. staging)"
          className="rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300 w-64"
        />
        <button
          onClick={() => createMutation.mutate(newName)}
          disabled={!newName.trim() || createMutation.isPending}
          className="rounded-lg bg-accent-500 px-4 py-2 text-sm font-medium text-white hover:bg-accent-600 transition-colors disabled:opacity-50"
        >
          {createMutation.isPending ? "Creating..." : "Create"}
        </button>
      </div>

      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {!isLoading && namespaces.length === 0 && (
        <div className="rounded-lg border border-dashed p-12 text-center">
          <p className="text-sm text-muted-foreground">
            No namespaces defined.
          </p>
        </div>
      )}

      {namespaces.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-surface-800">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-surface-800 bg-surface-900/50">
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Name</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Created</th>
                <th className="px-4 py-2.5 text-right font-medium text-surface-400">Actions</th>
              </tr>
            </thead>
            <tbody>
              {namespaces.map((ns) => (
                <tr key={ns.name} className="border-b border-surface-800/50 hover:bg-surface-900/30">
                  <td className="px-4 py-2 font-medium text-surface-200">{ns.name}</td>
                  <td className="px-4 py-2 text-surface-400 text-xs whitespace-nowrap">
                    {new Date(ns.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <button
                      onClick={() => deleteMutation.mutate(ns.name)}
                      disabled={ns.name === "default" || deleteMutation.isPending}
                      className="text-xs text-red-400 hover:text-red-300 disabled:opacity-30 disabled:cursor-not-allowed"
                    >
                      Delete
                    </button>
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
