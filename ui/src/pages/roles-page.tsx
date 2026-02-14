import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post, del } from "@/lib/api";

interface AuthPermission {
  resource: string;
  actions: string[];
}

interface AuthRole {
  name: string;
  permissions: AuthPermission[];
  created_at: string;
  updated_at?: string;
}

export default function RolesPage() {
  const qc = useQueryClient();
  const { data: roles = [], isLoading } = useQuery({
    queryKey: ["auth-roles"],
    queryFn: () => api<AuthRole[]>("/auth/roles"),
  });

  const [editing, setEditing] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [permissions, setPermissions] = useState<AuthPermission[]>([
    { resource: "", actions: [] },
  ]);

  const saveMutation = useMutation({
    mutationFn: (role: { name: string; permissions: AuthPermission[] }) =>
      post("/auth/roles", role),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["auth-roles"] });
      resetEditor();
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (name: string) => del(`/auth/roles/${name}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["auth-roles"] }),
  });

  function resetEditor() {
    setEditing(null);
    setNewName("");
    setPermissions([{ resource: "", actions: [] }]);
  }

  function startEdit(role: AuthRole) {
    setEditing(role.name);
    setNewName(role.name);
    setPermissions(
      role.permissions.length > 0
        ? role.permissions
        : [{ resource: "", actions: [] }],
    );
  }

  function startCreate() {
    setEditing("__new__");
    setNewName("");
    setPermissions([{ resource: "", actions: [] }]);
  }

  function updatePermission(
    index: number,
    field: "resource" | "actions",
    value: string | string[],
  ) {
    setPermissions((prev) =>
      prev.map((p, i) => (i === index ? { ...p, [field]: value } : p)),
    );
  }

  function addPermissionRow() {
    setPermissions((prev) => [...prev, { resource: "", actions: [] }]);
  }

  function removePermissionRow(index: number) {
    setPermissions((prev) => prev.filter((_, i) => i !== index));
  }

  const allActions = ["read", "write", "delete", "pause", "resume", "drain", "clear", "retry", "cancel", "approve", "reject", "hold"];

  function handleSave() {
    const name = newName.trim();
    const filtered = permissions.filter((p) => p.resource.trim() && p.actions.length > 0);
    if (!name || filtered.length === 0) return;
    saveMutation.mutate({ name, permissions: filtered });
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Roles</h1>
          <p className="text-sm text-muted-foreground">
            Manage RBAC roles and their permissions.
          </p>
        </div>
        {!editing && (
          <button
            onClick={startCreate}
            className="rounded-lg bg-accent-500 px-4 py-2 text-sm font-medium text-white hover:bg-accent-600 transition-colors"
          >
            Create Role
          </button>
        )}
      </div>

      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {!isLoading && roles.length === 0 && !editing && (
        <div className="rounded-lg border border-dashed p-12 text-center">
          <p className="text-sm text-muted-foreground">
            No roles defined. Create a role to get started with RBAC.
          </p>
        </div>
      )}

      {roles.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-surface-800">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-surface-800 bg-surface-900/50">
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Name</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Permissions</th>
                <th className="px-4 py-2.5 text-left font-medium text-surface-400">Created</th>
                <th className="px-4 py-2.5 text-right font-medium text-surface-400">Actions</th>
              </tr>
            </thead>
            <tbody>
              {roles.map((role) => (
                <tr key={role.name} className="border-b border-surface-800/50 hover:bg-surface-900/30">
                  <td className="px-4 py-2 font-medium text-surface-200">{role.name}</td>
                  <td className="px-4 py-2 text-surface-300">
                    {role.permissions.map((p) => (
                      <span
                        key={p.resource}
                        className="mr-2 inline-block rounded bg-surface-800 px-1.5 py-0.5 text-xs"
                      >
                        {p.resource}: {p.actions.join(", ")}
                      </span>
                    ))}
                  </td>
                  <td className="px-4 py-2 text-surface-400 text-xs whitespace-nowrap">
                    {new Date(role.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <button
                      onClick={() => startEdit(role)}
                      className="mr-2 text-xs text-accent-400 hover:text-accent-300"
                    >
                      Edit
                    </button>
                    <button
                      onClick={() => deleteMutation.mutate(role.name)}
                      className="text-xs text-red-400 hover:text-red-300"
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

      {editing && (
        <div className="rounded-lg border border-surface-700 bg-surface-900 p-4 space-y-4">
          <h2 className="text-lg font-semibold">
            {editing === "__new__" ? "Create Role" : `Edit Role: ${editing}`}
          </h2>

          <div>
            <label className="block text-sm font-medium text-surface-400 mb-1">
              Role Name
            </label>
            <input
              type="text"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              disabled={editing !== "__new__"}
              className="w-full max-w-xs rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300 disabled:opacity-50"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-surface-400 mb-2">
              Permissions
            </label>
            {permissions.map((perm, idx) => (
              <div key={idx} className="mb-2 flex items-start gap-2">
                <input
                  type="text"
                  value={perm.resource}
                  onChange={(e) => updatePermission(idx, "resource", e.target.value)}
                  placeholder="Resource (e.g. queues, jobs, *)"
                  className="rounded-lg border border-surface-700 bg-surface-800 px-3 py-1.5 text-sm text-surface-300 w-48"
                />
                <div className="flex flex-wrap gap-1">
                  {allActions.map((action) => (
                    <label
                      key={action}
                      className="flex items-center gap-1 rounded bg-surface-800 px-2 py-1 text-xs text-surface-300 cursor-pointer"
                    >
                      <input
                        type="checkbox"
                        checked={perm.actions.includes(action)}
                        onChange={(e) => {
                          const next = e.target.checked
                            ? [...perm.actions, action]
                            : perm.actions.filter((a) => a !== action);
                          updatePermission(idx, "actions", next);
                        }}
                        className="rounded"
                      />
                      {action}
                    </label>
                  ))}
                </div>
                {permissions.length > 1 && (
                  <button
                    onClick={() => removePermissionRow(idx)}
                    className="text-xs text-red-400 hover:text-red-300 mt-1"
                  >
                    Remove
                  </button>
                )}
              </div>
            ))}
            <button
              onClick={addPermissionRow}
              className="text-xs text-accent-400 hover:text-accent-300"
            >
              + Add permission row
            </button>
          </div>

          <div className="flex gap-2">
            <button
              onClick={handleSave}
              disabled={saveMutation.isPending}
              className="rounded-lg bg-accent-500 px-4 py-2 text-sm font-medium text-white hover:bg-accent-600 transition-colors disabled:opacity-50"
            >
              {saveMutation.isPending ? "Saving..." : "Save"}
            </button>
            <button
              onClick={resetEditor}
              className="rounded-lg border border-surface-700 px-4 py-2 text-sm font-medium text-surface-300 hover:bg-surface-800 transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
