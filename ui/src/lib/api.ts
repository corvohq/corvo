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
  const res = await fetch(`/api/v1${path}`, {
    ...opts,
    headers: {
      "Content-Type": "application/json",
      ...opts?.headers,
    },
  });
  if (!res.ok) {
    let body: { error: string; code: string };
    try {
      body = await res.json();
    } catch {
      body = { error: res.statusText, code: "UNKNOWN" };
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

// --- Settings / Org types and functions ---

export interface Org {
  id: string;
  name: string;
  created_at: string;
}

export interface OrgMember {
  id: string;
  name: string;
  email: string;
  role: string;
  created_at: string;
}

export interface ApiKey {
  id: string;
  name: string;
  key?: string; // only present on creation
  prefix: string;
  created_at: string;
}

export function getOrg(): Promise<Org> {
  return api<Org>("/org");
}

export function updateOrg(name: string): Promise<{ status: string }> {
  return put<{ status: string }>("/org", { name });
}

export function listMembers(): Promise<OrgMember[]> {
  return api<OrgMember[]>("/org/members");
}

export function removeMember(id: string): Promise<{ status: string }> {
  return del<{ status: string }>(`/org/members/${id}`);
}

export function listApiKeys(): Promise<ApiKey[]> {
  return api<ApiKey[]>("/org/api-keys");
}

export function createApiKey(name: string): Promise<ApiKey> {
  return post<ApiKey>("/org/api-keys", { name });
}

export function deleteApiKey(id: string): Promise<{ status: string }> {
  return del<{ status: string }>(`/org/api-keys/${id}`);
}
