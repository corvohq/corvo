import { test, expect } from "@playwright/test";

const BASE = "http://localhost:18080";
const AUTH = { Authorization: "Bearer test123" };

test.describe("Webhooks page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/webhooks");
  });

  test("renders heading", async ({ page }) => {
    await expect(
      page.getByRole("heading", { name: "Webhooks" })
    ).toBeVisible();
  });

  test("shows empty state when no webhooks exist", async ({ page }) => {
    await expect(page.getByText("No webhooks configured")).toBeVisible();
  });

  test("Add Webhook button toggles form visibility", async ({ page }) => {
    const form = page.locator("#create-webhook-form");
    await expect(form).toBeHidden();
    await page.getByRole("button", { name: "Add Webhook" }).click();
    await expect(form).toBeVisible();
    await page.getByRole("button", { name: "Add Webhook" }).click();
    await expect(form).toBeHidden();
  });

  test("form has URL input and event checkboxes", async ({ page }) => {
    await page.getByRole("button", { name: "Add Webhook" }).click();
    const form = page.locator("#create-webhook-form");
    await expect(form.locator("input[name='url']")).toBeVisible();
    await expect(form.locator("input[name='queue']")).toBeVisible();
    await expect(
      form.locator("input[name='event_completed']")
    ).toBeAttached();
    await expect(form.locator("input[name='event_failed']")).toBeAttached();
    await expect(form.locator("input[name='event_dead']")).toBeAttached();
    await expect(
      form.getByRole("button", { name: "Create" })
    ).toBeVisible();
  });

  test("event checkboxes are checked by default", async ({ page }) => {
    await page.getByRole("button", { name: "Add Webhook" }).click();
    const form = page.locator("#create-webhook-form");
    await expect(form.locator("input[name='event_completed']")).toBeChecked();
    await expect(form.locator("input[name='event_failed']")).toBeChecked();
    await expect(form.locator("input[name='event_dead']")).toBeChecked();
  });
});

test.describe("Webhooks CRUD", () => {
  test("create webhook via form and verify table row", async ({ page }) => {
    await page.goto("/ui/webhooks");
    await page.getByRole("button", { name: "Add Webhook" }).click();

    const form = page.locator("#create-webhook-form");
    await form.locator("input[name='url']").fill("http://localhost:9999/hook");
    await form.getByRole("button", { name: "Create" }).click();

    await page.waitForLoadState("load");
    await expect(
      page.getByText("http://localhost:9999/hook")
    ).toBeVisible({ timeout: 5_000 });
  });

  test("created webhook appears in table via API", async ({ page }) => {
    const resp = await fetch(`${BASE}/api/v1/webhooks`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({
        url: "http://test-api.local:8080/callback",
        queue: "orders",
        events: ["job.completed", "job.dead"],
      }),
    });
    expect(resp.status).toBe(201);

    await page.goto("/ui/webhooks");
    const row = page.locator("tr", {
      hasText: "http://test-api.local:8080/callback",
    });
    await expect(row).toBeVisible();
    await expect(row.getByText("orders")).toBeVisible();
  });

  test("delete webhook removes it from table", async ({ page }) => {
    // Create via API.
    const createResp = await fetch(`${BASE}/api/v1/webhooks`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({
        url: "http://delete-me.local/hook",
        events: ["job.completed"],
      }),
    });
    expect(createResp.status).toBe(201);
    const { id } = await createResp.json();
    expect(id).toBeTruthy();

    await page.goto("/ui/webhooks");
    await expect(
      page.getByText("http://delete-me.local/hook")
    ).toBeVisible();

    // Click delete and accept confirm dialog.
    page.on("dialog", (d) => d.accept());
    const row = page.locator("tr", {
      hasText: "http://delete-me.local/hook",
    });
    await row.getByRole("button", { name: "Delete" }).click();

    await page.waitForLoadState("load");
    await expect(
      page.getByText("http://delete-me.local/hook")
    ).not.toBeVisible({ timeout: 5_000 });
  });

  test("GET /api/v1/webhooks returns created webhook", async () => {
    const createResp = await fetch(`${BASE}/api/v1/webhooks`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({
        url: "http://list-test.local/hook",
        queue: "*",
        events: ["job.failed"],
      }),
    });
    expect(createResp.status).toBe(201);

    const listResp = await fetch(`${BASE}/api/v1/webhooks`, {
      headers: AUTH,
    });
    expect(listResp.status).toBe(200);
    const webhooks = await listResp.json();
    expect(Array.isArray(webhooks)).toBe(true);
    const found = webhooks.find(
      (w: { url: string }) => w.url === "http://list-test.local/hook"
    );
    expect(found).toBeTruthy();
    expect(found.events).toContain("job.failed");
  });
});
