const API_KEY_STORAGE_KEY = "corvo_api_key";

export function getStoredApiKey(): string | null {
  return localStorage.getItem(API_KEY_STORAGE_KEY);
}

export function setStoredApiKey(key: string): void {
  localStorage.setItem(API_KEY_STORAGE_KEY, key);
}

export function clearStoredApiKey(): void {
  localStorage.removeItem(API_KEY_STORAGE_KEY);
}

// Fires when the server requires auth and we have no valid key.
type AuthListener = () => void;
const authListeners = new Set<AuthListener>();
export function onAuthRequired(fn: AuthListener): () => void {
  authListeners.add(fn);
  return () => authListeners.delete(fn);
}
function fireAuthRequired() {
  authListeners.forEach((fn) => fn());
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public body: { error: string; code: string },
  ) {
    super(body.error || `HTTP ${status}`);
  }
}

export async function api<T>(
  path: string,
  opts?: RequestInit,
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(opts?.headers as Record<string, string>),
  };
  const apiKey = getStoredApiKey();
  if (apiKey) {
    headers["X-API-Key"] = apiKey;
  }
  const res = await fetch(`/api/v1${path}`, {
    ...opts,
    headers,
  });
  if (!res.ok) {
    let body: { error: string; code: string };
    try {
      body = await res.json();
    } catch {
      body = { error: res.statusText, code: "UNKNOWN" };
    }
    // If we got 401, try to recover.
    if (res.status === 401) {
      // If we sent a stored key, it may be stale — clear it and retry
      // without auth (works when the server has zero keys configured).
      if (apiKey) {
        clearStoredApiKey();
        const { "X-API-Key": _, ...retryHeaders } = headers;
        const retry = await fetch(`/api/v1${path}`, {
          ...opts,
          headers: retryHeaders,
        });
        if (retry.ok) {
          return retry.json();
        }
      }
      // Server requires auth and we have no valid key — prompt the user.
      fireAuthRequired();
    }
    throw new ApiError(res.status, body);
  }
  return res.json();
}

export function post<T>(path: string, body?: unknown): Promise<T> {
  return api<T>(path, {
    method: "POST",
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

export function put<T>(path: string, body?: unknown): Promise<T> {
  return api<T>(path, {
    method: "PUT",
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

export function del<T>(path: string): Promise<T> {
  return api<T>(path, { method: "DELETE" });
}

// --- Auth API key types and functions ---

export interface AuthKey {
  key_hash: string;
  name: string;
  namespace: string;
  role: string;
  queue_scope?: string;
  enabled: boolean;
  created_at: string;
  last_used_at?: string;
  expires_at?: string;
}

export function listAuthKeys(): Promise<AuthKey[]> {
  return api<AuthKey[]>("/auth/keys");
}

export function createAuthKey(req: {
  name: string;
  namespace: string;
  role: string;
  queue_scope?: string;
  expires_at?: string;
}): Promise<{ status: string; api_key: string }> {
  return post<{ status: string; api_key: string }>("/auth/keys", req);
}

export function deleteAuthKey(keyHash: string): Promise<{ status: string }> {
  return api<{ status: string }>("/auth/keys", {
    method: "DELETE",
    body: JSON.stringify({ key_hash: keyHash }),
  });
}

export function listAuthKeyRoles(
  keyHash: string,
): Promise<{ roles: string[] }> {
  return api<{ roles: string[] }>(`/auth/keys/${keyHash}/roles`);
}

export function assignAuthKeyRole(
  keyHash: string,
  role: string,
): Promise<{ status: string }> {
  return post<{ status: string }>(`/auth/keys/${keyHash}/roles`, { role });
}

export function unassignAuthKeyRole(
  keyHash: string,
  role: string,
): Promise<{ status: string }> {
  return del<{ status: string }>(`/auth/keys/${keyHash}/roles/${role}`);
}

// --- Audit log types and functions ---

export interface AuditLog {
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

export function listAuditLogs(
  params?: Record<string, string>,
): Promise<{ audit_logs: AuditLog[] }> {
  const qs = params ? `?${new URLSearchParams(params).toString()}` : "";
  return api<{ audit_logs: AuditLog[] }>(`/audit-logs${qs}`);
}

// --- RBAC role types and functions ---

export interface AuthPermission {
  resource: string;
  actions: string[];
}

export interface AuthRole {
  name: string;
  permissions: AuthPermission[];
  created_at: string;
  updated_at?: string;
}

export function listAuthRoles(): Promise<AuthRole[]> {
  return api<AuthRole[]>("/auth/roles");
}

export function setAuthRole(
  name: string,
  permissions: AuthPermission[],
): Promise<{ status: string }> {
  return post<{ status: string }>("/auth/roles", { name, permissions });
}

export function deleteAuthRole(name: string): Promise<{ status: string }> {
  return del<{ status: string }>(`/auth/roles/${name}`);
}

// --- Namespace types and functions ---

export interface Namespace {
  name: string;
  created_at: string;
}

export function listNamespaces(): Promise<Namespace[]> {
  return api<Namespace[]>("/namespaces");
}

export function createNamespace(name: string): Promise<{ status: string }> {
  return post<{ status: string }>("/namespaces", { name });
}

export function deleteNamespace(name: string): Promise<{ status: string }> {
  return del<{ status: string }>(`/namespaces/${name}`);
}

// --- SSO settings types and functions ---

export interface SSOSettings {
  provider: string;
  oidc_issuer_url: string;
  oidc_client_id: string;
  saml_enabled: boolean;
  updated_at?: string;
}

export function getSSOSettings(): Promise<SSOSettings> {
  return api<SSOSettings>("/settings/sso");
}

export function setSSOSettings(settings: Omit<SSOSettings, "updated_at">): Promise<{ status: string }> {
  return post<{ status: string }>("/settings/sso", settings);
}
