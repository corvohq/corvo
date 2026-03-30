import { test, expect, Page } from "@playwright/test";

const BASE = "http://localhost:18080";
const AUTH = { Authorization: "Bearer test123" };

async function expectToast(page: Page, type: "success" | "error" = "success") {
  const toast = page.locator("#toast div").first();
  await expect(toast).toBeVisible({ timeout: 5_000 });
  if (type === "success") {
    await expect(toast.locator("svg.text-emerald-500")).toBeVisible();
  } else {
    await expect(toast.locator("svg.text-red-500")).toBeVisible();
  }
}

async function enqueueJob(
  queue: string,
  opts?: { scheduled_at?: string; payload?: unknown },
): Promise<string> {
  const body: Record<string, unknown> = { queue };
  if (opts?.scheduled_at) body.scheduled_at = opts.scheduled_at;
  if (opts?.payload !== undefined) body.payload = opts.payload;
  const resp = await fetch(`${BASE}/api/v1/enqueue`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...AUTH },
    body: JSON.stringify(body),
  });
  const data = await resp.json();
  return data.job.id;
}

async function cancelJob(jobId: string) {
  await fetch(`${BASE}/api/v1/jobs/${jobId}/cancel`, { method: "POST", headers: AUTH });
}

// ─── State change verification ─────────────────────────────────────────────

test.describe("State change: pause flips badge", () => {
  test("pause shows Paused badge on queue detail", async ({ page }) => {
    await enqueueJob("test.cover.pause");
    await page.goto("/ui/queues/test.cover.pause");
    // Badge is the span immediately after h2.
    const badge = page.locator("h2 + span");
    await expect(badge).toHaveText("Active");
    await page.getByRole("button", { name: "Pause" }).click();
    // htmx triggers reload. Wait for the new page.
    await page.waitForLoadState("load");
    await expect(badge).toHaveText("Paused", { timeout: 5_000 });
  });
});

test.describe("State change: cancel changes job state", () => {
  test("cancel changes state badge to cancelled", async ({ page }) => {
    const jobId = await enqueueJob("test.cover.cancel.state");
    await page.goto(`/ui/jobs/${jobId}`);
    // State badge is span after the font-mono h2.
    const badge = page.locator("h2.font-mono + span");
    await expect(badge).toHaveText("pending");
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Cancel" }).click();
    await page.waitForLoadState("load");
    await expect(badge).toHaveText("cancelled", { timeout: 5_000 });
  });
});

test.describe("State change: promote changes scheduled to pending", () => {
  test("promote changes state badge to pending", async ({ page }) => {
    const future = new Date(Date.now() + 3600_000).toISOString();
    const jobId = await enqueueJob("test.cover.promote.state", { scheduled_at: future });
    await page.goto(`/ui/jobs/${jobId}`);
    const badge = page.locator("h2.font-mono + span");
    await expect(badge).toHaveText("scheduled");
    await page.getByRole("button", { name: "Run Now" }).click();
    await page.waitForLoadState("load");
    await expect(badge).toHaveText("pending", { timeout: 5_000 });
  });
});

test.describe("State change: delete removes job", () => {
  test("delete makes job unfindable via API", async ({ page }) => {
    const jobId = await enqueueJob("test.cover.delete.state");
    await page.goto(`/ui/jobs/${jobId}`);
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await page.waitForLoadState("load");
    // Verify job no longer exists via API.
    const resp = await fetch(`${BASE}/api/v1/jobs/${jobId}`, { headers: AUTH });
    expect(resp.status).toBe(404);
  });
});

// ─── Error toast content ──────��──────────────────────────────────────��─────

test.describe("Error toast renders with message", () => {
  test("error toast shows red icon and message text", async ({ page }) => {
    await page.goto("/ui/");
    // Directly invoke the toast function to verify rendering.
    await page.evaluate(() => {
      (window as any).corvoToast("error", "Something went wrong");
    });
    const toast = page.locator("#toast div").first();
    await expect(toast).toBeVisible({ timeout: 3_000 });
    await expect(toast.locator("svg.text-red-500")).toBeVisible();
    await expect(toast.locator("span")).toHaveText("Something went wrong");
  });
});

// ─── Bulk action end-to-end ──────────────────────────────────────────��─────

test.describe("Bulk: Cancel All changes job states", () => {
  test("bulk cancel moves jobs to cancelled", async ({ page }) => {
    const id1 = await enqueueJob("test.cover.bulk.cancel");
    const id2 = await enqueueJob("test.cover.bulk.cancel");
    await page.goto("/ui/queues/test.cover.bulk.cancel");

    const selectAll = page.locator("#select-all");
    await selectAll.check();
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: /cancel all/i }).click();

    // corvoBulkAction triggers fetch then location.reload().
    await page.waitForLoadState("load");
    // Verify via API — single job GET returns flat JSON.
    const r1 = await (await fetch(`${BASE}/api/v1/jobs/${id1}`, { headers: AUTH })).json();
    const r2 = await (await fetch(`${BASE}/api/v1/jobs/${id2}`, { headers: AUTH })).json();
    expect(r1.state).toBe("cancelled");
    expect(r2.state).toBe("cancelled");
  });
});

test.describe("Bulk: Delete All removes jobs", () => {
  test("bulk delete removes jobs", async ({ page }) => {
    const id1 = await enqueueJob("test.cover.bulk.delete");
    const id2 = await enqueueJob("test.cover.bulk.delete");
    await page.goto("/ui/queues/test.cover.bulk.delete");

    const selectAll = page.locator("#select-all");
    await selectAll.check();
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: /delete all/i }).click();

    await page.waitForLoadState("load");
    // Deleted jobs return 404.
    const r1 = await fetch(`${BASE}/api/v1/jobs/${id1}`, { headers: AUTH });
    const r2 = await fetch(`${BASE}/api/v1/jobs/${id2}`, { headers: AUTH });
    expect(r1.status).toBe(404);
    expect(r2.status).toBe(404);
  });
});

// ─── Job detail with payload ─────────────────────────────────────���─────────

test.describe("Job detail: payload renders with Copy button", () => {
  test("job with payload shows payload section and Copy", async ({ page }) => {
    const jobId = await enqueueJob("test.cover.payload", {
      payload: { message: "hello", count: 42 },
    });
    await page.goto(`/ui/jobs/${jobId}`);
    const payloadPre = page.locator("#job-payload");
    await expect(payloadPre).toBeVisible();
    const text = await payloadPre.textContent();
    expect(text).toContain("hello");
    expect(text).toContain("42");
    await expect(page.getByRole("button", { name: "Copy" })).toBeVisible();
  });

  test("job without payload shows 'No payload'", async ({ page }) => {
    const jobId = await enqueueJob("test.cover.no.payload");
    await page.goto(`/ui/jobs/${jobId}`);
    await expect(page.getByText("No payload")).toBeVisible();
    await expect(page.locator("#job-payload")).not.toBeVisible();
  });
});

// ─── Requeued job shows parent link ────���───────────────────────────────────

test.describe("Requeued job shows parent link", () => {
  test("requeue creates new job with 'Requeued From' link", async ({ page }) => {
    const parentId = await enqueueJob("test.cover.parent");
    await cancelJob(parentId);

    // Requeue via API.
    await fetch(`${BASE}/api/v1/jobs/${parentId}/requeue`, { method: "POST", headers: AUTH });

    // Find the new pending job in this queue.
    const listResp = await fetch(`${BASE}/api/v1/jobs`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ queue: "test.cover.parent", state: ["pending"] }),
    });
    const listData = await listResp.json();
    expect(listData.jobs.length).toBeGreaterThan(0);
    // The pending job is the requeued one (parent is cancelled).
    const newJobId = listData.jobs[0].id;

    // Visit the new job's detail page.
    await page.goto(`/ui/jobs/${newJobId}`);
    await expect(page.getByText("Requeued From")).toBeVisible();
    const parentLink = page.locator(`a[href="/ui/jobs/${parentId}"]`);
    await expect(parentLink).toBeVisible();
    await expect(parentLink).toHaveText(parentId);
  });
});

// ─── Dark mode toggle ────��──────────────────────────────────��──────────────

test.describe("Dark mode toggle", () => {
  test("clicking toggle adds dark class to html element", async ({ page }) => {
    await page.goto("/ui/");
    await page.evaluate(() => localStorage.removeItem("theme"));
    await page.goto("/ui/");

    const darkToggle = page.locator(
      "button[onclick*='document.documentElement.classList.toggle']",
    );
    await expect(darkToggle).toBeVisible();

    const hadDark = await page.evaluate(() =>
      document.documentElement.classList.contains("dark"),
    );

    await darkToggle.click();

    const hasDarkNow = await page.evaluate(() =>
      document.documentElement.classList.contains("dark"),
    );
    expect(hasDarkNow).toBe(!hadDark);

    const storedTheme = await page.evaluate(() => localStorage.getItem("theme"));
    expect(storedTheme).toBe(hasDarkNow ? "dark" : "light");

    // Click again to flip back.
    await darkToggle.click();
    const hasDarkAfter = await page.evaluate(() =>
      document.documentElement.classList.contains("dark"),
    );
    expect(hasDarkAfter).toBe(hadDark);
  });
});

// ─── API edge cases ──────────��─────────────────────────────────────────────

test.describe("API edge cases", () => {
  test("requeue on pending job is a no-op (state stays pending)", async () => {
    const jobId = await enqueueJob("test.cover.edge.requeue");
    const resp = await fetch(`${BASE}/api/v1/jobs/${jobId}/requeue`, { method: "POST", headers: AUTH });
    expect(resp.status).toBe(200);
    // State should still be pending — requeue only works on terminal states.
    const job = await (await fetch(`${BASE}/api/v1/jobs/${jobId}`, { headers: AUTH })).json();
    expect(job.state).toBe("pending");
  });

  test("cancel on already-cancelled job is a no-op", async () => {
    const jobId = await enqueueJob("test.cover.edge.cancel");
    await cancelJob(jobId);
    // Cancel again — should be no-op since already terminal.
    const resp = await fetch(`${BASE}/api/v1/jobs/${jobId}/cancel`, { method: "POST", headers: AUTH });
    expect(resp.status).toBe(200);
    const job = await (await fetch(`${BASE}/api/v1/jobs/${jobId}`, { headers: AUTH })).json();
    expect(job.state).toBe("cancelled");
  });

  test("delete on nonexistent job returns 200 (affected: 0)", async () => {
    const resp = await fetch(`${BASE}/api/v1/jobs/nonexistent-fake-id/delete`, {
      method: "POST",
      headers: AUTH,
    });
    expect(resp.status).toBe(200);
    const body = await resp.json();
    expect(body.affected).toBe(0);
  });
});
