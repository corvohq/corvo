import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  api,
  ApiError,
  listAuthKeys,
  createAuthKey,
  deleteAuthKey,
  listAuthKeyRoles,
  assignAuthKeyRole,
  unassignAuthKeyRole,
  setStoredApiKey,
} from "@/lib/api";
import type { AuthKey, Namespace } from "@/lib/api";
import { Copy, ChevronDown, ChevronRight, X, AlertTriangle } from "lucide-react";

const BUILT_IN_ROLES = ["admin", "operator", "worker", "readonly"];

export default function ApiKeysPage() {
  const qc = useQueryClient();
  const {
    data: keys = [],
    isLoading,
    error,
  } = useQuery({
    queryKey: ["auth-keys"],
    queryFn: listAuthKeys,
  });

  const { data: namespaces = [] } = useQuery({
    queryKey: ["namespaces"],
    queryFn: () => api<Namespace[]>("/namespaces"),
  });

  const { data: authStatus } = useQuery({
    queryKey: ["auth-status"],
    queryFn: () => api<{ admin_password_set: boolean }>("/auth/status"),
  });

  const [name, setName] = useState("");
  const [namespace, setNamespace] = useState("default");
  const [role, setRole] = useState("admin");
  const [queueScope, setQueueScope] = useState("");
  const [expiresAt, setExpiresAt] = useState("");
  const [createdKey, setCreatedKey] = useState<string | null>(null);
  const [expandedKey, setExpandedKey] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  const createMut = useMutation({
    mutationFn: () =>
      createAuthKey({
        name: name.trim(),
        namespace,
        role,
        queue_scope: queueScope.trim() || undefined,
        expires_at: expiresAt ? new Date(expiresAt).toISOString() : undefined,
      }),
    onSuccess: (data) => {
      // Always store the new key so subsequent requests authenticate.
      // A stale key from a previously-deleted key must be replaced.
      setStoredApiKey(data.api_key);
      setCreatedKey(data.api_key);
      setName("");
      setShowCreate(false);
      toast.success("API key created");
      // Optimistically add the key to the cache. The Raft write may not
      // have propagated to the SQLite read view yet, so an immediate
      // refetch would return stale data and overwrite this.
      // React Query will naturally sync on window focus or staleTime expiry.
      qc.setQueryData<AuthKey[]>(["auth-keys"], (old = []) => [
        ...old,
        {
          key_hash: data.api_key.slice(0, 16), // placeholder until refetch
          name: name.trim(),
          namespace,
          role,
          queue_scope: queueScope.trim() || undefined,
          enabled: true,
          created_at: new Date().toISOString(),
        } as AuthKey,
      ]);
      setQueueScope("");
      setExpiresAt("");
    },
    onError: (err) => toast.error(String(err)),
  });

  const deleteMut = useMutation({
    mutationFn: (keyHash: string) => deleteAuthKey(keyHash),
    onSuccess: (_data, keyHash) => {
      // Optimistically remove the key from the cache so the table
      // updates instantly, regardless of Raft→SQLite propagation delay.
      qc.setQueryData<AuthKey[]>(["auth-keys"], (old = []) =>
        old.filter((k) => k.key_hash !== keyHash),
      );
      toast.success("API key deleted");
    },
    onError: (err) => toast.error(String(err)),
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold">API Keys</h1>
        <p className="text-sm text-muted-foreground">
          Manage authentication keys for API access.
        </p>
      </div>

      {authStatus && !authStatus.admin_password_set && (
        <div className="flex items-start gap-3 rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-4">
          <AlertTriangle className="h-5 w-5 text-yellow-400 shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-yellow-400">
              No admin password set
            </p>
            <p className="mt-1 text-xs text-muted-foreground">
              If you lose your API keys, you will be locked out. Set an admin password
              with <code className="rounded bg-muted px-1 py-0.5">--admin-password</code> or
              the <code className="rounded bg-muted px-1 py-0.5">CORVO_ADMIN_PASSWORD</code> environment
              variable to ensure you can always access the server.
            </p>
          </div>
        </div>
      )}

      {createdKey && (
        <div className="rounded-lg border border-green-500/30 bg-green-500/5 p-4">
          <p className="mb-2 text-sm font-medium text-green-400">
            Copy this key now. It cannot be retrieved later.
          </p>
          <div className="flex items-center gap-2">
            <code className="flex-1 rounded bg-muted px-3 py-2 font-mono text-sm text-foreground break-all">
              {createdKey}
            </code>
            <button
              onClick={() => {
                navigator.clipboard.writeText(createdKey);
                toast.success("Copied to clipboard");
              }}
              className="rounded-lg border border-border p-2 text-muted-foreground hover:text-foreground transition-colors"
            >
              <Copy className="h-4 w-4" />
            </button>
          </div>
          <button
            onClick={() => setCreatedKey(null)}
            className="mt-2 text-xs text-muted-foreground hover:text-foreground"
          >
            Dismiss
          </button>
        </div>
      )}

      {/* Create form */}
      {!showCreate ? (
        <button
          onClick={() => setShowCreate(true)}
          className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors"
        >
          Create API Key
        </button>
      ) : (
        <div className="rounded-lg border border-border bg-card p-4 space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-foreground">
              Create API Key
            </h2>
            <button
              onClick={() => setShowCreate(false)}
              className="text-xs text-muted-foreground hover:text-foreground"
            >
              Cancel
            </button>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">
                Name *
              </label>
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g. production-worker"
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">
                Namespace
              </label>
              <select
                value={namespace}
                onChange={(e) => setNamespace(e.target.value)}
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              >
                {namespaces.length === 0 && (
                  <option value="default">default</option>
                )}
                {namespaces.map((ns) => (
                  <option key={ns.name} value={ns.name}>
                    {ns.name}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">
                Role
              </label>
              <select
                value={role}
                onChange={(e) => setRole(e.target.value)}
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              >
                {BUILT_IN_ROLES.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">
                Queue Scope
              </label>
              <input
                type="text"
                value={queueScope}
                onChange={(e) => setQueueScope(e.target.value)}
                placeholder="Optional prefix"
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">
                Expires At
              </label>
              <input
                type="datetime-local"
                value={expiresAt}
                onChange={(e) => setExpiresAt(e.target.value)}
                className="w-full rounded-lg border border-border bg-muted px-3 py-1.5 text-sm text-foreground"
              />
            </div>
          </div>
          <button
            onClick={() => createMut.mutate()}
            disabled={!name.trim() || createMut.isPending}
            className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50"
          >
            {createMut.isPending ? "Creating..." : "Create Key"}
          </button>
        </div>
      )}

      {/* Keys table */}
      {isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">
          Loading...
        </p>
      )}

      {!isLoading && error && (
        <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-6 text-center">
          <p className="text-sm text-yellow-400">
            {error instanceof ApiError && error.status === 403
              ? "Listing API keys requires authentication. Create your first key above."
              : `Failed to load keys: ${error.message}`}
          </p>
        </div>
      )}

      {!isLoading && !error && keys.length === 0 && (
        <div className="rounded-lg border border-dashed p-12 text-center">
          <p className="text-sm text-muted-foreground">
            No API keys defined. Create a key to get started.
          </p>
        </div>
      )}

      {keys.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground w-8" />
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Name
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Namespace
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Role
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Status
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Queue Scope
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Last Used
                </th>
                <th className="px-4 py-2.5 text-left font-medium text-muted-foreground">
                  Expires
                </th>
                <th className="px-4 py-2.5 text-right font-medium text-muted-foreground">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              {keys.map((key) => (
                <KeyRow
                  key={key.key_hash}
                  authKey={key}
                  expanded={expandedKey === key.key_hash}
                  onToggle={() =>
                    setExpandedKey(
                      expandedKey === key.key_hash ? null : key.key_hash,
                    )
                  }
                  onDelete={() => deleteMut.mutate(key.key_hash)}
                  deleting={deleteMut.isPending}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function KeyRow({
  authKey,
  expanded,
  onToggle,
  onDelete,
  deleting,
}: {
  authKey: AuthKey;
  expanded: boolean;
  onToggle: () => void;
  onDelete: () => void;
  deleting: boolean;
}) {
  return (
    <>
      <tr className="border-b border-border/50 hover:bg-muted/30">
        <td className="px-4 py-2">
          <button onClick={onToggle} className="text-muted-foreground hover:text-foreground">
            {expanded ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </button>
        </td>
        <td className="px-4 py-2 font-medium text-foreground">
          {authKey.name}
        </td>
        <td className="px-4 py-2 text-foreground">
          <span className="rounded bg-muted px-1.5 py-0.5 text-xs">
            {authKey.namespace}
          </span>
        </td>
        <td className="px-4 py-2 text-foreground">
          <span className="rounded bg-muted px-1.5 py-0.5 text-xs">
            {authKey.role}
          </span>
        </td>
        <td className="px-4 py-2">
          <span
            className={`rounded px-1.5 py-0.5 text-xs font-medium ${
              authKey.enabled
                ? "bg-green-500/10 text-green-400"
                : "bg-red-500/10 text-red-400"
            }`}
          >
            {authKey.enabled ? "Enabled" : "Disabled"}
          </span>
        </td>
        <td className="px-4 py-2 text-muted-foreground text-xs">
          {authKey.queue_scope || "—"}
        </td>
        <td className="px-4 py-2 text-muted-foreground text-xs whitespace-nowrap">
          {authKey.last_used_at
            ? new Date(authKey.last_used_at).toLocaleDateString()
            : "Never"}
        </td>
        <td className="px-4 py-2 text-muted-foreground text-xs whitespace-nowrap">
          {authKey.expires_at
            ? new Date(authKey.expires_at).toLocaleDateString()
            : "Never"}
        </td>
        <td className="px-4 py-2 text-right">
          <button
            onClick={onDelete}
            disabled={deleting}
            className="text-xs text-red-400 hover:text-red-300 disabled:opacity-50"
          >
            Delete
          </button>
        </td>
      </tr>
      {expanded && (
        <tr className="border-b border-border/50">
          <td colSpan={9} className="px-4 py-3 bg-muted/20">
            <RolesPanel keyHash={authKey.key_hash} />
          </td>
        </tr>
      )}
    </>
  );
}

function RolesPanel({ keyHash }: { keyHash: string }) {
  const qc = useQueryClient();
  const [newRole, setNewRole] = useState("");
  const {
    data,
    isLoading,
    error,
  } = useQuery({
    queryKey: ["auth-key-roles", keyHash],
    queryFn: () => listAuthKeyRoles(keyHash),
  });

  const assignMut = useMutation({
    mutationFn: (role: string) => assignAuthKeyRole(keyHash, role),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["auth-key-roles", keyHash] });
      setNewRole("");
    },
    onError: (err) => toast.error(String(err)),
  });

  const unassignMut = useMutation({
    mutationFn: (role: string) => unassignAuthKeyRole(keyHash, role),
    onSuccess: () =>
      qc.invalidateQueries({ queryKey: ["auth-key-roles", keyHash] }),
    onError: (err) => toast.error(String(err)),
  });

  if (error instanceof ApiError && error.status === 403) {
    return (
      <p className="text-xs text-muted-foreground">
        Custom RBAC role assignment requires an enterprise license.
      </p>
    );
  }

  if (isLoading) {
    return <p className="text-xs text-muted-foreground">Loading roles...</p>;
  }

  const roles = data?.roles ?? [];

  return (
    <div className="space-y-2">
      <p className="text-xs font-medium text-muted-foreground">
        Custom RBAC Roles
      </p>
      {roles.length === 0 && (
        <p className="text-xs text-muted-foreground">
          No custom roles assigned.
        </p>
      )}
      <div className="flex flex-wrap gap-1.5">
        {roles.map((r) => (
          <span
            key={r}
            className="inline-flex items-center gap-1 rounded bg-muted px-2 py-0.5 text-xs text-foreground"
          >
            {r}
            <button
              onClick={() => unassignMut.mutate(r)}
              className="text-muted-foreground hover:text-red-400"
            >
              <X className="h-3 w-3" />
            </button>
          </span>
        ))}
      </div>
      <div className="flex items-center gap-2">
        <input
          type="text"
          value={newRole}
          onChange={(e) => setNewRole(e.target.value)}
          placeholder="Role name"
          className="rounded-lg border border-border bg-muted px-2 py-1 text-xs text-foreground w-40"
        />
        <button
          onClick={() => assignMut.mutate(newRole.trim())}
          disabled={!newRole.trim() || assignMut.isPending}
          className="text-xs text-primary hover:text-primary/80 disabled:opacity-50"
        >
          Assign
        </button>
      </div>
    </div>
  );
}
