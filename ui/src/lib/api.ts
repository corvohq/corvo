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

export function del<T>(path: string): Promise<T> {
  return api<T>(path, { method: "DELETE" });
}
