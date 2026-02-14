import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, post, del, ApiError } from "@/lib/api";

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
  const { data: roles = [], isLoading, error } = useQuery({
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

  const allResources = [
    "*",
    "jobs",
    "queues",
    "budgets",
    "approval-policies",
    "webhooks",
    "auth",
    "namespaces",
    "settings",
    "admin",
    "workers",
    "audit-logs",
    "org",
    "billing",
  ];

  const allActions = ["*", "read", "write", "delete", "pause", "resume", "drain", "clear", "retry", "cancel", "approve", "reject", "hold"];

  const validPermissions = permissions.filter((p) => p.resource.trim() && p.actions.length > 0);
  const canSave = newName.trim().length > 0 && validPermissions.length > 0;
  const missingName = newName.trim().length === 0;
  const missingPerms = validPermissions.length === 0;

  function handleSave() {
    if (!canSave) return;
    saveMutation.mutate({ name: newName.trim(), permissions: validPermissions });
  }

  const builtInRoles = [
    { name: "admin", description: "Full access to all resources and operations" },
    { name: "operator", description: "Full access except cannot create or modify API keys" },
    { name: "worker", description: "Can enqueue, fetch, ack, fail, and heartbeat jobs. Read-only access to job details" },
    { name: "readonly", description: "Read-only access (GET requests only)" },
  ];

  if (error instanceof ApiError && error.status === 403) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold">Roles</h1>
          <p className="text-sm text-muted-foreground">
            Manage RBAC roles and their permissions.
          </p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4">
          <h2 className="text-sm font-semibold text-foreground mb-1">Built-in Roles</h2>
          <p className="text-xs text-muted-foreground mb-3">These are always available and cannot be modified.</p>
          <div className="space-y-2">
            {builtInRoles.map((r) => (
              <div key={r.name} className="flex items-baseline gap-3">
                <span className="rounded bg-muted px-1.5 py-0.5 text-xs font-medium text-foreground w-20 text-center">{r.name}</span>
                <span className="text-xs text-muted-foreground">{r.description}</span>
              </div>
            ))}
          </div>
        </div>
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-6 text-center">
          <p className="text-sm text-yellow-400">
            Custom RBAC roles require an enterprise license.
          </p>
        </div>
      </div>
    );
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
            className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors"
          >
            Create Role
          </button>
        )}
      </div>

      {/* Built-in roles */}
      <div className="rounded-lg border border-border bg-card p-4">
        <h2 className="text-sm font-semibold text-foreground mb-1">Built-in Roles</h2>
        <p className="text-xs text-muted-foreground mb-3">These are always available and cannot be modified.</p>
        <div className="space-y-2">
          {builtInRoles.map((r) => (
            <div key={r.name} className="flex items-baseline gap-3">
              <span className="rounded bg-muted px-1.5 py-0.5 text-xs font-medium text-foreground w-20 text-center">{r.name}</span>
              <span className="text-xs text-muted-foreground">{r.description}</span>
            </div>
          ))}
        </div>
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
        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Name</th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Permissions</th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">Created</th>
                <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">Actions</th>
              </tr>
            </thead>
            <tbody>
              {roles.map((role) => (
                <tr key={role.name} className="border-b border-border/50 hover:bg-muted/30">
                  <td className="px-4 py-2 font-medium text-foreground">{role.name}</td>
                  <td className="px-4 py-2 text-foreground">
                    {role.permissions.map((p) => (
                      <span
                        key={p.resource}
                        className="mr-2 inline-block rounded bg-muted px-1.5 py-0.5 text-xs"
                      >
                        {p.resource}: {p.actions.join(", ")}
                      </span>
                    ))}
                  </td>
                  <td className="px-4 py-2 text-muted-foreground text-xs whitespace-nowrap">
                    {new Date(role.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <button
                      onClick={() => startEdit(role)}
                      className="mr-2 text-xs text-primary hover:text-primary/80"
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
        <div className="rounded-lg border border-border bg-card p-4 space-y-4">
          <h2 className="text-lg font-semibold">
            {editing === "__new__" ? "Create Role" : `Edit Role: ${editing}`}
          </h2>

          <div>
            <label className="block text-sm font-medium text-muted-foreground mb-1">
              Role Name
            </label>
            <input
              type="text"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              disabled={editing !== "__new__"}
              className="w-full max-w-xs rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground disabled:opacity-50"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-muted-foreground mb-2">
              Permissions
            </label>
            {permissions.map((perm, idx) => (
              <div key={idx} className="mb-3 flex items-start gap-2">
                <div className="w-48 shrink-0">
                  <select
                    value={perm.resource}
                    onChange={(e) => updatePermission(idx, "resource", e.target.value)}
                    className="rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground w-full"
                  >
                    <option value="">Select resource...</option>
                    {allResources.map((r) => (
                      <option key={r} value={r}>
                        {r === "*" ? "All resources" : r}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="flex flex-wrap gap-1">
                  {allActions.map((action) => {
                    const isWildcard = action === "*";
                    const hasWildcard = perm.actions.includes("*");
                    return (
                      <label
                        key={action}
                        className="flex items-center gap-1 rounded bg-muted px-2 py-1 text-xs text-foreground cursor-pointer"
                      >
                        <input
                          type="checkbox"
                          checked={perm.actions.includes(action)}
                          disabled={!isWildcard && hasWildcard}
                          onChange={(e) => {
                            let next: string[];
                            if (isWildcard) {
                              next = e.target.checked ? ["*"] : [];
                            } else {
                              next = e.target.checked
                                ? [...perm.actions.filter((a) => a !== "*"), action]
                                : perm.actions.filter((a) => a !== action);
                            }
                            updatePermission(idx, "actions", next);
                          }}
                          className="rounded"
                        />
                        {isWildcard ? "all" : action}
                      </label>
                    );
                  })}
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
              className="text-xs text-primary hover:text-primary/80"
            >
              + Add permission row
            </button>
          </div>

          {saveMutation.isError && (
            <p className="text-sm text-red-400">
              Failed to save role: {saveMutation.error?.message ?? "unknown error"}
            </p>
          )}

          <div className="flex items-center gap-2">
            <button
              onClick={handleSave}
              disabled={!canSave || saveMutation.isPending}
              className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {saveMutation.isPending ? "Saving..." : "Save"}
            </button>
            <button
              onClick={resetEditor}
              className="rounded-lg border border-border px-4 py-2 text-sm font-medium text-foreground hover:bg-muted transition-colors"
            >
              Cancel
            </button>
            {!canSave && (
              <span className="text-xs text-muted-foreground">
                {missingName && missingPerms
                  ? "Enter a role name and add at least one permission."
                  : missingName
                    ? "Enter a role name."
                    : "Select a resource and at least one action."}
              </span>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
