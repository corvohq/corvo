import { test, expect } from "@playwright/test";

test.describe("Dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/");
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
  });

  test("shows seeded queue names", async ({ page }) => {
    await expect(page.getByRole("link", { name: "emails" })).toBeVisible();
    await expect(page.getByRole("link", { name: "payments" })).toBeVisible();
  });

  test("shows summary stat cards", async ({ page }) => {
    const main = page.locator("main");
    await expect(main.getByText("Total Pending")).toBeVisible();
    await expect(main.getByText("Active").first()).toBeVisible();
    await expect(main.getByText("Workers")).toBeVisible();
  });

  test("Enqueue Job button is present", async ({ page }) => {
    await expect(page.getByRole("button", { name: /^enqueue$/i })).toBeVisible();
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
    await expect(page.getByRole("heading", { name: "emails" })).toBeVisible();
  });
});

test.describe("Queue detail", () => {
  test("shows queue name and action buttons", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    await expect(page.getByRole("heading", { name: "emails" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Pause" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Resume" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Drain" })).toBeVisible();
  });

  test("shows jobs in table", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    const rows = page.locator("table tbody tr");
    await expect(rows.first()).toBeVisible();
    // Row links to job detail.
    await expect(rows.first().locator("a")).toBeVisible();
  });

  test("has select-all checkbox and bulk bar appears", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    const selectAll = page.locator("#select-all");
    await expect(selectAll).toBeVisible();
    await selectAll.check();
    await expect(page.getByText(/\d+ selected/)).toBeVisible();
  });
});

test.describe("Queue detail: filter and export", () => {
  test("filter tabs are present", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    await expect(page.getByRole("link", { name: /all/i }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: /pending/i }).first()).toBeVisible();
  });

  test("client-side text filter narrows rows", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    const rows = page.locator("table tbody tr");
    const initialCount = await rows.count();
    // Type a filter that won't match anything.
    await page.locator("input[placeholder='Filter jobs...']").fill("zzz-no-match");
    // All rows should be hidden.
    await expect(rows.first()).toBeHidden();
    // Clear filter to restore.
    await page.locator("input[placeholder='Filter jobs...']").fill("");
    await expect(rows).toHaveCount(initialCount);
  });

  test("export buttons are visible", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    await expect(page.getByRole("button", { name: "JSON" })).toBeVisible();
    await expect(page.getByRole("button", { name: "CSV" })).toBeVisible();
  });
});

test.describe("Queue detail: stats cards", () => {
  test("shows stats cards for queue", async ({ page }) => {
    await page.goto("/ui/queues/emails");
    await expect(page.getByText("Pending", { exact: true }).first()).toBeVisible();
    await expect(page.getByText("Dead", { exact: true }).first()).toBeVisible();
  });
});

test.describe("HTMX auto-refresh", () => {
  test("dashboard stats container has hx-trigger", async ({ page }) => {
    await page.goto("/ui/");
    const statsDiv = page.locator("[hx-get='/ui/partials/dashboard-stats']");
    await expect(statsDiv).toHaveAttribute("hx-trigger", /every/);
  });

  test("queues table container has hx-trigger", async ({ page }) => {
    await page.goto("/ui/queues");
    const tableDiv = page.locator("[hx-get='/ui/partials/queues-table']");
    await expect(tableDiv).toHaveAttribute("hx-trigger", /every/);
  });
});

test.describe("Dark mode", () => {
  test("toggle button exists in header", async ({ page }) => {
    await page.goto("/ui/");
    // Dark mode toggle is next to the Enqueue button in the header.
    const headerActions = page.locator("main .flex.items-center.gap-2").first();
    const toggleBtn = headerActions.locator("button").first();
    await expect(toggleBtn).toBeVisible();
  });
});

test.describe("API: metrics and cluster endpoints", () => {
  test("throughput endpoint returns JSON", async ({ request }) => {
    const resp = await request.get("/api/v1/metrics/throughput");
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("enqueue_rate");
    expect(body).toHaveProperty("per_second");
  });

  test("cluster events endpoint returns JSON", async ({ request }) => {
    const resp = await request.get("/api/v1/cluster/events");
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("events");
    expect(Array.isArray(body.events)).toBe(true);
  });

  test("cluster status endpoint returns JSON", async ({ request }) => {
    const resp = await request.get("/api/v1/cluster/status");
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("state");
    expect(body).toHaveProperty("node_id");
  });

  test("prometheus metrics endpoint returns text", async ({ request }) => {
    const resp = await request.get("/metrics");
    expect(resp.status()).toBe(200);
    const text = await resp.text();
    expect(text).toContain("corvo_enqueued_total");
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
    // Pending job should show Cancel + Delete (not Requeue).
    await expect(page.getByRole("button", { name: "Cancel" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Delete" })).toBeVisible();
    await expect(page.getByRole("button", { name: "Requeue" })).not.toBeVisible();
    // Should show job metadata table.
    await expect(page.getByRole("cell", { name: "Queue" })).toBeVisible();
    await expect(page.getByRole("cell", { name: "State" })).toBeVisible();
    await expect(page.getByRole("cell", { name: "Priority" })).toBeVisible();
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
