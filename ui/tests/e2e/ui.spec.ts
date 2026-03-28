import { test, expect } from "@playwright/test";

test.describe("Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/");
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  });

  test("shows seeded queue names", async ({ page }) => {
    await expect(page.getByText("emails")).toBeVisible();
    await expect(page.getByText("payments")).toBeVisible();
  });

  test("shows summary stat cards", async ({ page }) => {
    await expect(page.getByText("Pending")).toBeVisible();
    await expect(page.getByText("Active")).toBeVisible();
    await expect(page.getByText("Workers")).toBeVisible();
  });

  test("Enqueue Job button is present", async ({ page }) => {
    await expect(page.getByRole("button", { name: /enqueue job/i })).toBeVisible();
  });

  test("sidebar navigation links present", async ({ page }) => {
    await expect(page.getByRole("link", { name: "Dashboard" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Queues" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Workers" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Cluster" })).toBeVisible();
  });
});

test.describe("Queues page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/queues");
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Queues" })).toBeVisible();
  });

  test("shows seeded queues in table", async ({ page }) => {
    await expect(page.getByRole("link", { name: "emails" })).toBeVisible();
    await expect(page.getByRole("link", { name: "payments" })).toBeVisible();
    await expect(page.getByRole("link", { name: "reports" })).toBeVisible();
  });

  test("queue links navigate to detail page", async ({ page }) => {
    await page.getByRole("link", { name: "emails" }).click();
    await expect(page).toHaveURL(/\/ui\/queues\/emails/);
    await expect(page.getByText("emails")).toBeVisible();
  });
});

test.describe("Queue detail", () => {
  test("shows queue name and action buttons", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    await expect(page.getByText("emails")).toBeVisible();
    await expect(page.getByRole("button", { name: "Pause" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Resume" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Drain" })).toBeVisible();
  });

  test("shows jobs in table with action buttons", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    const rows = page.locator("table tbody tr");
    await expect(rows.first()).toBeVisible();
    // Row has Cancel and Delete action buttons.
    await expect(rows.first().getByRole("button", { name: "Cancel" })).toBeVisible();
    await expect(rows.first().getByRole("button", { name: "Delete" })).toBeVisible();
  });

  test("has select-all checkbox and bulk bar appears", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    const selectAll = page.locator("#select-all");
    await expect(selectAll).toBeVisible();
    await selectAll.check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();
  });
});

test.describe("Dead Letter", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/dead-letter");
    await expect(page.getByRole("heading", { name: /dead letter/i })).toBeVisible();
  });
});

test.describe("Held Jobs", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/held");
    await expect(page.getByRole("heading", { name: "Held Jobs" })).toBeVisible();
  });
});

test.describe("Scheduled Jobs", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/scheduled");
    await expect(page.getByRole("heading", { name: /scheduled/i })).toBeVisible();
  });
});

test.describe("Job Detail", () => {
  test("navigating to a job shows its detail", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    // Click the first job link.
    const jobLink = page.locator("table tbody tr a").first();
    await jobLink.click();
    await expect(page).toHaveURL(/\/ui\/jobs\//);
    // Should show job detail with action buttons.
    await expect(page.getByRole("button", { name: "Retry" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Cancel" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Delete" })).toBeVisible();
    // Should show job metadata.
    await expect(page.getByText("Queue")).toBeVisible();
    await expect(page.getByText("State")).toBeVisible();
    await expect(page.getByText("Priority")).toBeVisible();
  });
});

test.describe("Workers", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/workers");
    await expect(page.getByRole("heading", { name: "Workers" })).toBeVisible();
  });

  test("shows empty state when no workers", async ({ page }) => {
    await page.goto("/ui/workers");
    await expect(page.getByText("No workers connected")).toBeVisible();
  });
});

test.describe("Cluster Status", () => {
  test("renders heading", async ({ page }) => {
    await page.goto("/ui/cluster");
    await expect(page.getByRole("heading", { name: "Cluster" })).toBeVisible();
  });

  test("shows standalone mode", async ({ page }) => {
    await page.goto("/ui/cluster");
    await expect(page.getByText("Standalone Mode")).toBeVisible();
    await expect(page.getByText("leader")).toBeVisible();
  });
});
