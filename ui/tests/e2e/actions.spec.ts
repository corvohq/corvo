import { test, expect, Page } from "@playwright/test";

const TOAST_TIMEOUT = 4_000;

async function expectToast(page: Page) {
  // Toast shows "Done" or "Error" briefly.
  await expect(page.locator("#toast").getByText("Done")).toBeVisible({ timeout: TOAST_TIMEOUT });
}

// Enqueue a job via the HTMX form.
async function enqueueViaUI(page: Page, queue: string) {
  await page.goto("/ui/");
  await page.getByRole("button", { name: /enqueue job/i }).click();
  // Wait for the modal form to load via HTMX.
  await expect(page.locator("#modal form")).toBeVisible({ timeout: 3_000 });
  await page.locator("input[name='queue']").fill(queue);
  await page.getByRole("button", { name: "Enqueue" }).click();
  await expectToast(page);
}

// ─── Enqueue Job ─────────────────────────────────────────────────────────────

test.describe("Enqueue Job dialog", () => {
  test("opens from dashboard and enqueues a job", async ({ page }) => {
    await page.goto("/ui/");
    await page.getByRole("button", { name: /enqueue job/i }).click();
    await expect(page.locator("#modal form")).toBeVisible({ timeout: 3_000 });

    await page.locator("input[name='queue']").fill("test.enqueue");
    await page.getByRole("button", { name: "Enqueue" }).click();
    await expectToast(page);
    // Modal should close after successful enqueue.
    await expect(page.locator("#modal form")).not.toBeVisible();
  });

  test("cancel closes the dialog", async ({ page }) => {
    await page.goto("/ui/");
    await page.getByRole("button", { name: /enqueue job/i }).click();
    await expect(page.locator("#modal form")).toBeVisible({ timeout: 3_000 });
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.locator("#modal form")).not.toBeVisible();
  });
});

// ─── Queue actions ────────────────────────────────────────────────────────────

test.describe("Queue: Pause / Resume", () => {
  test("pausing a queue shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.pause");
    await page.goto("/ui/queues/test.pause");
    await page.getByRole("button", { name: "Pause" }).click();
    await expectToast(page);
  });

  test("resuming a queue shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.resume");
    await page.goto("/ui/queues/test.resume");
    await page.getByRole("button", { name: "Resume" }).click();
    await expectToast(page);
  });
});

test.describe("Queue: Drain", () => {
  test("draining a queue shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.drain");
    await page.goto("/ui/queues/test.drain");
    await page.getByRole("button", { name: "Drain" }).click();
    await expectToast(page);
  });
});

// ─── Job actions (from detail page) ──────────────────────────────────────────

test.describe("Job: Retry", () => {
  test("retry button shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.retry");
    await page.goto("/ui/queues/test.retry");
    // Navigate to job detail.
    await page.locator("table tbody tr a").first().click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await page.getByRole("button", { name: "Retry" }).click();
    await expectToast(page);
  });
});

test.describe("Job: Cancel", () => {
  test("cancel button shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.cancel");
    await page.goto("/ui/queues/test.cancel");
    await page.locator("table tbody tr a").first().click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await page.getByRole("button", { name: "Cancel" }).click();
    await expectToast(page);
  });
});

test.describe("Job: Delete", () => {
  test("delete button shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.delete");
    await page.goto("/ui/queues/test.delete");
    await page.locator("table tbody tr a").first().click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await page.getByRole("button", { name: "Delete" }).click();
    await expectToast(page);
  });
});

// ─── Row-level actions ───────────────────────────────────────────────────────

test.describe("Row actions: Queue detail", () => {
  test("cancel row action shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.row-cancel");
    await page.goto("/ui/queues/test.row-cancel");
    const firstRow = page.locator("table tbody tr").first();
    await firstRow.getByRole("button", { name: "Cancel" }).click();
    await expectToast(page);
  });
});

// ─── Bulk actions ────────────────────────────────────────────────────────────

test.describe("Bulk: Select all and action", () => {
  test("select-all checkbox shows bulk bar", async ({ page }) => {
    await enqueueViaUI(page, "test.bulk");
    await enqueueViaUI(page, "test.bulk");
    await page.goto("/ui/queues/test.bulk");

    const selectAll = page.locator("#select-all");
    await selectAll.check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();
    // Bulk bar buttons should be visible.
    await expect(page.getByRole("button", { name: /cancel all/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /delete all/i })).toBeVisible();
  });
});
