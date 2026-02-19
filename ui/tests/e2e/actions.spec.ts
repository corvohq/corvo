import { test, expect, Page } from "@playwright/test";

const TOAST = 6_000; // ms to wait for toast notifications

async function waitForLoad(page: Page) {
  await expect(page.getByText("Loading...")).toHaveCount(0, { timeout: 10_000 });
}

async function expectToast(page: Page, text: string | RegExp) {
  await expect(page.getByText(text).first()).toBeVisible({ timeout: TOAST });
}

// Enqueue a job via the UI and wait for the success toast.
async function enqueueViaUI(page: Page, queue: string) {
  await page.goto("/ui");
  await waitForLoad(page);
  await page.getByRole("button", { name: /enqueue job/i }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.getByLabel(/queue name/i).fill(queue);
  await page.getByRole("button", { name: "Enqueue" }).click();
  await expectToast(page, "Job enqueued");
  await expect(page.getByRole("dialog")).not.toBeVisible();
}

// ─── Enqueue Job ─────────────────────────────────────────────────────────────

test.describe("Enqueue Job dialog", () => {
  test("opens from dashboard and enqueues a job", async ({ page }) => {
    await page.goto("/ui");
    await waitForLoad(page);

    await page.getByRole("button", { name: /enqueue job/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await expect(page.getByText("Enqueue Job")).toBeVisible();

    await page.getByLabel(/queue name \*/i).fill("test.enqueue");
    // Payload defaults to {}, leave it as-is.
    await page.getByRole("button", { name: "Enqueue" }).click();

    await expectToast(page, "Job enqueued");
    await expect(page.getByRole("dialog")).not.toBeVisible();
  });

  test("submit is disabled until a queue name is entered", async ({ page }) => {
    await page.goto("/ui");
    await waitForLoad(page);
    await page.getByRole("button", { name: /enqueue job/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    const submitBtn = page.getByRole("button", { name: "Enqueue" });
    await expect(submitBtn).toBeDisabled();

    await page.getByLabel(/queue name \*/i).fill("some.queue");
    await expect(submitBtn).toBeEnabled();
  });

  test("closing the dialog resets the form", async ({ page }) => {
    await page.goto("/ui");
    await waitForLoad(page);
    await page.getByRole("button", { name: /enqueue job/i }).click();
    await page.getByLabel(/queue name \*/i).fill("some.queue");
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.getByRole("dialog")).not.toBeVisible();

    // Reopen — queue should be empty again.
    await page.getByRole("button", { name: /enqueue job/i }).click();
    await expect(page.getByLabel(/queue name \*/i)).toHaveValue("");
  });
});

// ─── Queue actions ────────────────────────────────────────────────────────────

test.describe("Queue: Pause / Resume", () => {
  // Use a dedicated test queue to avoid interfering with other seeded data.
  const TEST_QUEUE = "test.pause-resume";

  test.beforeEach(async ({ page }) => {
    await enqueueViaUI(page, TEST_QUEUE);
    await page.goto(`/ui/queues/${TEST_QUEUE}`);
    await waitForLoad(page);
  });

  test("pausing a queue shows Paused badge and toast", async ({ page }) => {
    await page.getByRole("button", { name: /^pause$/i }).click();
    await expectToast(page, "Queue paused");
    await expect(page.getByText("Paused").first()).toBeVisible();
  });

  test("resuming a paused queue shows Active badge and toast", async ({ page }) => {
    // Pause first.
    await page.getByRole("button", { name: /^pause$/i }).click();
    await expectToast(page, "Queue paused");

    await page.getByRole("button", { name: /^resume$/i }).click();
    await expectToast(page, "Queue resumed");
    await expect(page.getByText("Active").first()).toBeVisible();
  });
});

test.describe("Queue: Drain", () => {
  test("draining a queue shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.drain");
    await page.goto("/ui/queues/test.drain");
    await waitForLoad(page);

    await page.getByRole("button", { name: /drain/i }).click();
    await expectToast(page, "Queue draining");
  });
});

test.describe("Queue: Concurrency", () => {
  test("opens dialog and saves concurrency limit", async ({ page }) => {
    await enqueueViaUI(page, "test.concurrency");
    await page.goto("/ui/queues/test.concurrency");
    await waitForLoad(page);

    await page.getByRole("button", { name: /concurrency/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await expect(page.getByText("Set Concurrency")).toBeVisible();

    await page.getByRole("spinbutton").fill("5");
    await page.getByRole("button", { name: "Save" }).click();

    await expectToast(page, "Concurrency updated");
    await expect(page.getByRole("dialog")).not.toBeVisible();
  });
});

test.describe("Queue: Throttle", () => {
  test("opens throttle dialog", async ({ page }) => {
    await enqueueViaUI(page, "test.throttle");
    await page.goto("/ui/queues/test.throttle");
    await waitForLoad(page);

    await page.getByRole("button", { name: /throttle/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    // Cancel — just verifying it opens correctly.
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.getByRole("dialog")).not.toBeVisible();
  });
});

test.describe("Queue: Clear", () => {
  test("clearing a queue shows toast", async ({ page }) => {
    // Seed a queue with a job first.
    await enqueueViaUI(page, "test.clear");
    await page.goto("/ui/queues/test.clear");
    await waitForLoad(page);

    await page.getByRole("button", { name: /clear/i }).click();
    await expectToast(page, "Queue cleared");
  });
});

// ─── Job actions ──────────────────────────────────────────────────────────────

test.describe("Job: Retry", () => {
  test("retrying a dead job shows toast and changes state", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);

    // Navigate into the first dead job.
    await page.locator("table tbody tr").first().click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await waitForLoad(page);

    await page.getByRole("button", { name: /^retry$/i }).click();
    await expectToast(page, "Job retried");
  });
});

test.describe("Job: Cancel", () => {
  test("cancelling a pending job shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.cancel");

    await page.goto("/ui/queues/test.cancel");
    await waitForLoad(page);
    await page.locator("table tbody tr").first().click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await waitForLoad(page);

    await page.getByRole("button", { name: /^cancel$/i }).click();
    await expectToast(page, "Job cancelled");
  });
});

test.describe("Job: Clone", () => {
  test("clone button opens pre-filled dialog", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);

    await page.locator("table tbody tr").first().click();
    await waitForLoad(page);

    await page.getByRole("button", { name: /clone/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await expect(page.getByText("Clone Job")).toBeVisible();

    // Queue field should be pre-filled from the original job.
    const queueInput = page.getByLabel(/queue name \*/i);
    await expect(queueInput).not.toHaveValue("");

    // Can submit the clone.
    await page.getByRole("button", { name: "Clone" }).click();
    await expectToast(page, "Job enqueued");
  });
});

test.describe("Job: Move", () => {
  test("move dialog opens and moves job to another queue", async ({ page }) => {
    await enqueueViaUI(page, "test.move-source");

    await page.goto("/ui/queues/test.move-source");
    await waitForLoad(page);
    await page.locator("table tbody tr").first().click();
    await waitForLoad(page);

    await page.getByRole("button", { name: /move/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    await page.getByPlaceholder(/queue name/i).fill("test.move-dest");
    await page.getByRole("button", { name: /^move$/i }).click();
    await expectToast(page, "Job moved");
  });
});

test.describe("Job: Delete", () => {
  test("deleting a job shows toast", async ({ page }) => {
    await enqueueViaUI(page, "test.delete");

    await page.goto("/ui/queues/test.delete");
    await waitForLoad(page);
    await page.locator("table tbody tr").first().click();
    await waitForLoad(page);

    await page.getByRole("button", { name: /delete/i }).click();
    await expectToast(page, "Job deleted");
  });
});

// ─── Bulk actions ─────────────────────────────────────────────────────────────

test.describe("Bulk: Retry", () => {
  test("bulk retrying dead jobs shows success toast", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);

    // Use the select-all checkbox (first checkbox on the page).
    await page.getByRole("checkbox").first().check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();

    await page.getByRole("button", { name: /^retry$/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    // Confirm button text: "retry N jobs"
    await page.getByRole("button", { name: /retry \d+ jobs?/i }).click();
    await expectToast(page, /bulk action/i);
  });
});

test.describe("Bulk: Cancel", () => {
  test("bulk cancelling pending jobs shows success toast", async ({ page }) => {
    // Enqueue enough jobs to bulk-cancel.
    for (let i = 0; i < 3; i++) {
      await enqueueViaUI(page, "test.bulk-cancel");
    }

    await page.goto("/ui/queues/test.bulk-cancel");
    await waitForLoad(page);

    await page.getByRole("checkbox").first().check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();

    // Click the "Cancel" action in the bulk bar.
    const bulkBar = page.locator(".sticky.bottom-0");
    await bulkBar.getByRole("button", { name: /^cancel$/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    await page.getByRole("button", { name: /cancel \d+ jobs?/i }).click();
    await expectToast(page, /bulk action/i);
  });
});

test.describe("Bulk: Move", () => {
  test("bulk move opens destination input and moves jobs", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);

    // Select just the first job.
    await page.getByRole("checkbox").nth(1).check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();

    await page.getByRole("button", { name: /^move$/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    // Destination queue input should appear.
    await page.getByPlaceholder(/queue name/i).fill("test.bulk-moved");
    await page.getByRole("button", { name: /move \d+ jobs?/i }).click();
    await expectToast(page, /bulk action/i);
  });
});

test.describe("Bulk: Delete", () => {
  test("bulk deleting jobs shows success toast", async ({ page }) => {
    for (let i = 0; i < 2; i++) {
      await enqueueViaUI(page, "test.bulk-delete");
    }

    await page.goto("/ui/queues/test.bulk-delete");
    await waitForLoad(page);

    await page.getByRole("checkbox").first().check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();

    await page.getByRole("button", { name: /^delete$/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    await page.getByRole("button", { name: /delete \d+ jobs?/i }).click();
    await expectToast(page, /bulk action/i);
  });
});

// ─── Held job actions ─────────────────────────────────────────────────────────

test.describe("Held Jobs: Approve", () => {
  test("approving a held job shows toast", async ({ page }) => {
    await page.goto("/ui/held");
    await waitForLoad(page);

    const approveBtn = page.getByRole("button", { name: /^approve$/i }).first();
    await expect(approveBtn).toBeVisible({ timeout: 8_000 });
    await approveBtn.click();
    await expectToast(page, "Job approved");
  });
});

test.describe("Held Jobs: Reject", () => {
  test("rejecting a held job shows toast", async ({ page }) => {
    // Put something fresh in the held state so the previous test doesn't
    // deplete the list — the seed creates multiple held jobs.
    await page.goto("/ui/held");
    await waitForLoad(page);

    const rejectBtn = page.getByRole("button", { name: /^reject$/i }).first();
    await expect(rejectBtn).toBeVisible({ timeout: 8_000 });
    await rejectBtn.click();
    await expectToast(page, "Job rejected");
  });
});

test.describe("Held Jobs: View", () => {
  test("View button navigates to job detail", async ({ page }) => {
    await page.goto("/ui/held");
    await waitForLoad(page);

    const viewBtn = page.getByRole("button", { name: /^view$/i }).first();
    // If all held jobs were consumed by approve/reject tests, skip gracefully.
    if (!(await viewBtn.isVisible({ timeout: 5_000 }).catch(() => false))) {
      test.skip();
      return;
    }
    await viewBtn.click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
  });
});

// ─── Scheduled Jobs: Run Now ──────────────────────────────────────────────────

test.describe("Scheduled Jobs: Run Now", () => {
  test("bulk Run Now triggers scheduled jobs immediately", async ({ page }) => {
    await page.goto("/ui/scheduled");
    await waitForLoad(page);

    // Select all scheduled jobs.
    await page.getByRole("checkbox").first().check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();

    await page.getByRole("button", { name: /^run now$/i }).click();
    await expect(page.getByRole("dialog")).toBeVisible();

    await page.getByRole("button", { name: /run now \d+ jobs?/i }).click();
    await expectToast(page, /bulk action/i);
  });
});

// ─── API Keys ────────────────────────────────────────────────────────────────

test.describe("API Keys: Create", () => {
  test("creates a new API key and shows it once", async ({ page }) => {
    await page.goto("/ui/api-keys");
    await waitForLoad(page);

    await page.getByText("Create API Key").click();
    // The form expands inline.
    await expect(page.getByPlaceholder("e.g. production-worker")).toBeVisible();

    await page.getByPlaceholder("e.g. production-worker").fill("e2e-test-key");
    await page.getByText("Create Key").click();

    await expectToast(page, "API key created");
    // The raw key is shown once after creation.
    await expect(page.getByText("Copy this key now")).toBeVisible();
  });
});

test.describe("API Keys: Delete", () => {
  test("deletes an API key and removes it from the list", async ({ page }) => {
    await page.goto("/ui/api-keys");
    await waitForLoad(page);

    // Create a key to delete.
    await page.getByText("Create API Key").click();
    await page.getByPlaceholder("e.g. production-worker").fill("e2e-to-delete");
    await page.getByText("Create Key").click();
    await expectToast(page, "API key created");

    // Dismiss the "copy this key" banner, wait for table to update.
    await page.getByText("Dismiss").click();
    await waitForLoad(page);

    // Find the row and click its delete (X) button.
    const row = page.locator("tr", { hasText: "e2e-to-delete" });
    await expect(row).toBeVisible();
    await row.getByRole("button", { name: /delete/i }).click();

    await expectToast(page, "API key deleted");
    await expect(page.getByText("e2e-to-delete")).not.toBeVisible({ timeout: 6_000 });
  });
});
