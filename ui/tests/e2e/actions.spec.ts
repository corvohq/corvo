import { test, expect, Page } from "@playwright/test";

const BASE = "http://localhost:18080";

async function expectToast(page: Page, type: "success" | "error" = "success") {
  const toast = page.locator("#toast div").first();
  await expect(toast).toBeVisible({ timeout: 5_000 });
  if (type === "success") {
    // Success toast should have the green check icon
    await expect(toast.locator("svg.text-emerald-500")).toBeVisible();
  }
}

// Enqueue a job via API (faster than UI form).
async function enqueueJob(queue: string, opts?: { scheduled_at?: string }): Promise<string> {
  const body: any = { queue };
  if (opts?.scheduled_at) body.scheduled_at = opts.scheduled_at;
  const resp = await fetch(`${BASE}/api/v1/enqueue`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await resp.json();
  return data.job.id;
}

// Cancel a job via API to move it to cancelled (terminal) state.
async function cancelJob(jobId: string) {
  await fetch(`${BASE}/api/v1/jobs/${jobId}/cancel`, { method: "POST" });
}

// ─── Enqueue Job dialog ─────────────────────────────────────────────────────

test.describe("Enqueue Job dialog", () => {
  test("opens from dashboard and enqueues a job", async ({ page }) => {
    await page.goto("/ui/");
    await page.getByRole("button", { name: /^enqueue$/i }).first().click();
    const modal = page.locator("#modal");
    await expect(modal.locator("form")).toBeVisible({ timeout: 3_000 });

    await modal.locator("input[name='queue']").fill("test.enqueue");
    await modal.locator("button[type='submit']").click();
    await expectToast(page, "success");
    await expect(modal.locator("form")).not.toBeVisible();
  });

  test("cancel closes the dialog", async ({ page }) => {
    await page.goto("/ui/");
    await page.getByRole("button", { name: /^enqueue$/i }).first().click();
    const modal = page.locator("#modal");
    await expect(modal.locator("form")).toBeVisible({ timeout: 3_000 });
    await modal.getByRole("button", { name: "Cancel" }).click();
    await expect(modal.locator("form")).not.toBeVisible();
  });
});

// ─── Queue actions ──────────────────────────────────────────────────────────

test.describe("Queue: Pause / Resume", () => {
  test("pausing a queue shows success toast", async ({ page }) => {
    await enqueueJob("test.pause");
    await page.goto("/ui/queues/test.pause");
    await page.getByRole("button", { name: "Pause" }).click();
    await expectToast(page, "success");
  });

  test("resuming a queue shows success toast", async ({ page }) => {
    await enqueueJob("test.resume");
    await page.goto("/ui/queues/test.resume");
    await page.getByRole("button", { name: "Resume" }).click();
    await expectToast(page, "success");
  });
});

// ─── Job detail: state-conditional buttons ──────────────────────────────────

test.describe("Job detail: pending job buttons", () => {
  test("pending job shows Cancel and Delete, not Requeue", async ({ page }) => {
    const jobId = await enqueueJob("test.buttons.pending");
    await page.goto(`/ui/jobs/${jobId}`);
    await expect(page.getByRole("button", { name: "Cancel" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Delete" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Requeue" })).not.toBeVisible();
    await expect(page.getByRole("button", { name: "Run Now" })).not.toBeVisible();
  });
});

test.describe("Job detail: cancelled job buttons", () => {
  test("cancelled job shows Requeue and Delete, not Cancel", async ({ page }) => {
    const jobId = await enqueueJob("test.buttons.cancelled");
    await cancelJob(jobId);
    await page.goto(`/ui/jobs/${jobId}`);
    await expect(page.getByRole("button", { name: "Requeue" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Delete" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Cancel" })).not.toBeVisible();
  });
});

test.describe("Job detail: scheduled job buttons", () => {
  test("scheduled job shows Run Now, Cancel, Delete", async ({ page }) => {
    const future = new Date(Date.now() + 3600_000).toISOString();
    const jobId = await enqueueJob("test.buttons.scheduled", { scheduled_at: future });
    await page.goto(`/ui/jobs/${jobId}`);
    await expect(page.getByRole("button", { name: "Run Now" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Cancel" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Delete" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Requeue" })).not.toBeVisible();
  });
});

// ─── Job actions: verify they actually work ─────────────────────────────────

test.describe("Job: Cancel (with confirm)", () => {
  test("cancel succeeds on pending job", async ({ page }) => {
    const jobId = await enqueueJob("test.action.cancel");
    await page.goto(`/ui/jobs/${jobId}`);
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Cancel" }).click();
    await expectToast(page, "success");
  });
});

test.describe("Job: Delete (with confirm)", () => {
  test("delete succeeds on pending job", async ({ page }) => {
    const jobId = await enqueueJob("test.action.delete");
    await page.goto(`/ui/jobs/${jobId}`);
    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expectToast(page, "success");
  });
});

test.describe("Job: Requeue", () => {
  test("requeue succeeds on cancelled job", async ({ page }) => {
    const jobId = await enqueueJob("test.action.requeue");
    await cancelJob(jobId);
    await page.goto(`/ui/jobs/${jobId}`);
    await page.getByRole("button", { name: "Requeue" }).click();
    await expectToast(page, "success");
  });
});

test.describe("Job: Promote (Run Now)", () => {
  test("promote succeeds on scheduled job", async ({ page }) => {
    const future = new Date(Date.now() + 3600_000).toISOString();
    const jobId = await enqueueJob("test.action.promote", { scheduled_at: future });
    await page.goto(`/ui/jobs/${jobId}`);
    await page.getByRole("button", { name: "Run Now" }).click();
    await expectToast(page, "success");
  });
});

// ─── Job action routes return correct status codes ──────────────────────────

test.describe("Job action API routes", () => {
  test("DELETE route returns 200", async ({ request }) => {
    const jobId = await enqueueJob("test.api.delete");
    const resp = await request.post(`/api/v1/jobs/${jobId}/delete`);
    expect(resp.status()).toBe(200);
  });

  test("CANCEL route returns 200 on pending job", async ({ request }) => {
    const jobId = await enqueueJob("test.api.cancel");
    const resp = await request.post(`/api/v1/jobs/${jobId}/cancel`);
    expect(resp.status()).toBe(200);
  });

  test("REQUEUE route returns 200 on cancelled job", async ({ request }) => {
    const jobId = await enqueueJob("test.api.requeue");
    await cancelJob(jobId);
    const resp = await request.post(`/api/v1/jobs/${jobId}/requeue`);
    expect(resp.status()).toBe(200);
  });

  test("PROMOTE route returns 200 on scheduled job", async ({ request }) => {
    const future = new Date(Date.now() + 3600_000).toISOString();
    const jobId = await enqueueJob("test.api.promote", { scheduled_at: future });
    const resp = await request.post(`/api/v1/jobs/${jobId}/promote`);
    expect(resp.status()).toBe(200);
  });
});

// ─── Timestamp formatting ───────────────────────────────────────────────────

test.describe("Timestamp formatting", () => {
  test("time elements show relative format, not raw ISO", async ({ page }) => {
    const jobId = await enqueueJob("test.timestamps");
    await page.goto(`/ui/jobs/${jobId}`);
    const timeEl = page.locator("time[data-ts]").first();
    await expect(timeEl).toBeVisible();
    const text = await timeEl.textContent();
    // Should be relative ("Xs ago", "in Xd") not a raw ISO string like "2026-03-29T..."
    expect(text).not.toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(text).toMatch(/\d+[smhd]/);
  });
});

// ─── Bulk actions ───────────────────────────────────────────────────────────

test.describe("Bulk: Select all and action", () => {
  test("select-all checkbox shows bulk bar", async ({ page }) => {
    await enqueueJob("test.bulk");
    await enqueueJob("test.bulk");
    await page.goto("/ui/queues/test.bulk");

    const selectAll = page.locator("#select-all");
    await selectAll.check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();
    await expect(page.getByRole("button", { name: /cancel all/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /delete all/i })).toBeVisible();
  });
});
