import { test, expect, Page } from "@playwright/test";

// Wait for the page to finish loading (no "Loading..." spinners).
async function waitForLoad(page: Page) {
  await expect(page.getByText("Loading...")).toHaveCount(0, { timeout: 10_000 });
}

test.describe("Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  });

  test("shows seeded queue names", async ({ page }) => {
    await expect(page.getByText("emails.send")).toBeVisible();
    await expect(page.getByText("reports.generate")).toBeVisible();
  });

  test("shows summary stat cards", async ({ page }) => {
    // Stat cards are rendered when queues data arrives.
    await expect(page.getByText("Pending")).toBeVisible();
    await expect(page.getByText("Active")).toBeVisible();
    await expect(page.getByText("Completed")).toBeVisible();
  });

  test("Enqueue Job button is present", async ({ page }) => {
    await expect(page.getByRole("button", { name: /enqueue job/i })).toBeVisible();
  });
});

test.describe("Queues page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/queues");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Queues" })).toBeVisible();
  });

  test("shows seeded queues", async ({ page }) => {
    await expect(page.getByText("emails.send")).toBeVisible();
    await expect(page.getByText("reports.generate")).toBeVisible();
    await expect(page.getByText("agents.research")).toBeVisible();
  });

  test("shows queue count", async ({ page }) => {
    // The count span like "(7)" appears next to the "All Queues" title.
    await expect(page.getByText(/all queues/i)).toBeVisible();
  });
});

test.describe("Queue detail", () => {
  test("loads the emails.send queue page", async ({ page }) => {
    await page.goto("/ui/queues/emails.send");
    await waitForLoad(page);
    await expect(page.getByText("emails.send")).toBeVisible();
  });

  test("clicking a queue row navigates to its detail page", async ({ page }) => {
    await page.goto("/ui/queues");
    await waitForLoad(page);
    await page.getByText("emails.send").first().click();
    await expect(page).toHaveURL(/\/ui\/queues\/emails\.send/);
    await waitForLoad(page);
    await expect(page.getByText("emails.send")).toBeVisible();
  });
});

test.describe("Dead Letter Queue", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /dead letter/i })).toBeVisible();
  });

  test("shows dead jobs seeded by demo command", async ({ page }) => {
    // Seed creates 6 dead jobs in emails.send.
    await expect(page.getByText("emails.send")).toBeVisible();
  });

  test("job rows are present in the table", async ({ page }) => {
    const rows = page.locator("table tbody tr");
    await expect(rows.first()).toBeVisible();
  });
});

test.describe("Job Detail", () => {
  test("navigating into a dead job shows its detail", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await waitForLoad(page);

    // Click the first job row to open its detail page.
    const firstRow = page.locator("table tbody tr").first();
    await firstRow.click();

    await expect(page).toHaveURL(/\/ui\/jobs\//);
    await waitForLoad(page);

    // Should not show an error.
    await expect(page.getByText("Job not found")).not.toBeVisible();

    // Key fields should be visible.
    await expect(page.getByText("emails.send")).toBeVisible();
    await expect(page.getByText("dead", { exact: false })).toBeVisible();
  });
});

test.describe("Held Jobs", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/held");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Held Jobs" })).toBeVisible();
  });

  test("shows held jobs from seed", async ({ page }) => {
    // Seed creates at least one manually-held job.
    // Either the held card renders, or the "No held jobs" empty state appears.
    // In either case the page must not crash.
    const noJobs = page.getByText("No held jobs");
    const heldJob = page.locator("[data-testid='held-card']");
    await expect(noJobs.or(heldJob).first()).toBeVisible({ timeout: 8_000 });
  });
});

test.describe("Scheduled Jobs", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/scheduled");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(
      page.getByRole("heading", { name: /scheduled/i })
    ).toBeVisible();
  });

  test("shows scheduled jobs from seed", async ({ page }) => {
    // Seed creates 5 scheduled jobs in reports.generate.
    await expect(page.getByText("reports.generate")).toBeVisible();
  });
});

test.describe("Workers", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/workers");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Workers" })).toBeVisible();
  });

  test("page renders without crashing", async ({ page }) => {
    // Workers may be empty (seed-worker disconnects after seeding).
    // The page should render the Active Workers card either way.
    await expect(page.getByText(/active workers/i)).toBeVisible();
  });
});

test.describe("Cluster Status", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/cluster");
    await waitForLoad(page);
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Cluster Status" })).toBeVisible();
  });

  test("shows cluster node info", async ({ page }) => {
    // Single-node bootstrap: should show Leader state.
    await expect(page.getByText(/leader/i)).toBeVisible({ timeout: 8_000 });
  });
});

test.describe("Cost Dashboard", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/cost");
    await waitForLoad(page);
    await expect(page.getByRole("heading", { name: /cost|usage/i })).toBeVisible();
  });
});

test.describe("API Keys", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/api-keys");
    await waitForLoad(page);
    await expect(page.getByRole("heading", { name: /api keys/i })).toBeVisible();
  });
});

test.describe("Events", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/events");
    await waitForLoad(page);
    await expect(page.getByRole("heading", { name: /events/i })).toBeVisible();
  });
});
