import { test, expect } from "@playwright/test";

const BASE = "http://localhost:18080";
const AUTH = { Authorization: "Bearer test123" };

// Helper: clear audit logs before each test for isolation.
async function clearAuditLogs() {
  await fetch(`${BASE}/api/v1/audit-logs`, {
    method: "DELETE",
    headers: AUTH,
  });
}

test.describe("Audit Log page", () => {
  test.beforeEach(async () => {
    await clearAuditLogs();
  });

  test("renders heading and empty state", async ({ page }) => {
    await page.goto("/ui/audit-logs");
    await expect(
      page.getByRole("heading", { name: "Audit Log" })
    ).toBeVisible();
    await expect(page.getByText("No audit log entries")).toBeVisible();
  });

  test("sidebar has Audit Log link", async ({ page }) => {
    await page.goto("/ui/");
    await expect(page.getByRole("link", { name: "Audit Log" })).toBeVisible();
  });

  test("pause queue creates audit entry", async ({ page }) => {
    // Create queue by enqueueing a job.
    await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-test-q", payload: "test" }),
    });

    // Pause the queue (management op).
    const pauseResp = await fetch(
      `${BASE}/api/v1/queues/audit-test-q/pause`,
      { method: "POST", headers: AUTH }
    );
    expect(pauseResp.status).toBe(200);

    await page.goto("/ui/audit-logs");
    const row = page.locator("tbody tr", { hasText: "queue:audit-test-q" });
    await expect(row).toBeVisible();
    await expect(row.getByText("pause", { exact: true })).toBeVisible();
    await expect(row.getByText("admin")).toBeVisible();
  });

  test("cancel job creates audit entry", async ({ page }) => {
    // Enqueue a job.
    const enqResp = await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-cancel-q", payload: "cancel-me" }),
    });
    const { job } = await enqResp.json();

    // Cancel the job.
    const cancelResp = await fetch(
      `${BASE}/api/v1/jobs/${job.id}/cancel`,
      { method: "POST", headers: AUTH }
    );
    expect(cancelResp.status).toBe(200);

    await page.goto("/ui/audit-logs");
    const row = page.locator("tbody tr", { hasText: `job:${job.id}` });
    await expect(row).toBeVisible();
    await expect(row.getByText("cancel", { exact: true })).toBeVisible();
  });

  test("delete job creates audit entry", async ({ page }) => {
    // Enqueue then cancel (must be non-active to delete).
    const enqResp = await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-del-q", payload: "del-me" }),
    });
    const { job } = await enqResp.json();

    await fetch(`${BASE}/api/v1/jobs/${job.id}/cancel`, {
      method: "POST",
      headers: AUTH,
    });

    const delResp = await fetch(`${BASE}/api/v1/jobs/${job.id}`, {
      method: "DELETE",
      headers: AUTH,
    });
    expect(delResp.status).toBe(200);

    await page.goto("/ui/audit-logs");
    // Should have both cancel and delete entries.
    const rows = page.locator("tbody tr");
    await expect(rows.first()).toBeVisible();
    const text = await page.locator("tbody").textContent();
    expect(text).toContain("delete");
    expect(text).toContain("cancel");
  });

  test("GET /api/v1/audit-logs returns entries", async () => {
    // Pause a queue to generate an entry.
    await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-api-q", payload: "test" }),
    });
    await fetch(`${BASE}/api/v1/queues/audit-api-q/pause`, {
      method: "POST",
      headers: AUTH,
    });

    const resp = await fetch(`${BASE}/api/v1/audit-logs`, { headers: AUTH });
    expect(resp.status).toBe(200);
    const entries = await resp.json();
    expect(Array.isArray(entries)).toBe(true);
    expect(entries.length).toBeGreaterThan(0);

    const pause = entries.find(
      (e: { op: string }) => e.op === "pause"
    );
    expect(pause).toBeTruthy();
    expect(pause.target).toBe("queue:audit-api-q");
    expect(pause.actor).toBe("admin");
    expect(pause.ts).toBeGreaterThan(0);
  });

  test("DELETE /api/v1/audit-logs clears all entries", async () => {
    // Generate an entry.
    await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-clear-q", payload: "test" }),
    });
    await fetch(`${BASE}/api/v1/queues/audit-clear-q/pause`, {
      method: "POST",
      headers: AUTH,
    });

    // Verify entry exists.
    let resp = await fetch(`${BASE}/api/v1/audit-logs`, { headers: AUTH });
    let entries = await resp.json();
    expect(entries.length).toBeGreaterThan(0);

    // Clear.
    const delResp = await fetch(`${BASE}/api/v1/audit-logs`, {
      method: "DELETE",
      headers: AUTH,
    });
    expect(delResp.status).toBe(200);

    // Verify empty.
    resp = await fetch(`${BASE}/api/v1/audit-logs`, { headers: AUTH });
    entries = await resp.json();
    expect(entries.length).toBe(0);
  });

  test("Clear All button clears audit log via UI", async ({ page }) => {
    // Generate an entry.
    await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-ui-clear-q", payload: "test" }),
    });
    await fetch(`${BASE}/api/v1/queues/audit-ui-clear-q/pause`, {
      method: "POST",
      headers: AUTH,
    });

    await page.goto("/ui/audit-logs");
    const row = page.locator("tbody tr", { hasText: "queue:audit-ui-clear-q" });
    await expect(row).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Clear All" })
    ).toBeVisible();

    // Click clear and accept confirm dialog.
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Clear All" }).click();

    await page.waitForLoadState("load");
    await expect(page.getByText("No audit log entries")).toBeVisible({
      timeout: 5_000,
    });
  });

  test("newest entries appear first", async () => {
    // Generate two entries with different ops.
    await fetch(`${BASE}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "audit-order-q", payload: "test" }),
    });
    await fetch(`${BASE}/api/v1/queues/audit-order-q/pause`, {
      method: "POST",
      headers: AUTH,
    });
    await fetch(`${BASE}/api/v1/queues/audit-order-q/resume`, {
      method: "POST",
      headers: AUTH,
    });

    const resp = await fetch(`${BASE}/api/v1/audit-logs`, { headers: AUTH });
    const entries = await resp.json();
    expect(entries.length).toBeGreaterThanOrEqual(2);
    // Newest first: resume should come before pause.
    expect(entries[0].op).toBe("resume");
    expect(entries[1].op).toBe("pause");
  });

  test("webhook create generates audit entry", async () => {
    const createResp = await fetch(`${BASE}/api/v1/webhooks`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({
        url: "http://audit-webhook.local/hook",
        events: ["job.completed"],
      }),
    });
    expect(createResp.status).toBe(201);
    const { id } = await createResp.json();

    const resp = await fetch(`${BASE}/api/v1/audit-logs`, { headers: AUTH });
    const entries = await resp.json();
    const entry = entries.find(
      (e: { op: string }) => e.op === "webhook_create"
    );
    expect(entry).toBeTruthy();
    expect(entry.actor).toBe("admin");

    // Clean up webhook so later tests see empty state.
    await fetch(`${BASE}/api/v1/webhooks`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ id }),
    });
  });
});
