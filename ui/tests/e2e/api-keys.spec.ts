import { test, expect } from "@playwright/test";

const BASE = "http://localhost:18080";
const AUTH = { Authorization: "Bearer test123" };

test.describe("API Keys page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/ui/api-keys");
  });

  test("renders heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "API Keys" })).toBeVisible();
  });

  test("shows empty state when no keys exist", async ({ page }) => {
    await expect(page.getByText("No API keys configured")).toBeVisible();
  });

  test("shows admin-password requirement note", async ({ page }) => {
    await expect(page.getByText("--admin-password")).toBeVisible();
  });

  test("Create Key button toggles form visibility", async ({ page }) => {
    const form = page.locator("#create-key-form");
    await expect(form).toBeHidden();
    await page.getByRole("button", { name: "Create Key" }).click();
    await expect(form).toBeVisible();
    await page.getByRole("button", { name: "Create Key" }).click();
    await expect(form).toBeHidden();
  });

  test("form has name input and role select", async ({ page }) => {
    await page.getByRole("button", { name: "Create Key" }).click();
    const form = page.locator("#create-key-form");
    await expect(form.locator("input[name='name']")).toBeVisible();
    await expect(form.locator("select[name='role']")).toBeVisible();
    await expect(form.getByRole("button", { name: "Create" })).toBeVisible();
  });

  test("role select has admin, producer, worker options", async ({ page }) => {
    await page.getByRole("button", { name: "Create Key" }).click();
    const select = page.locator("#create-key-form select[name='role']");
    await expect(select.locator("option[value='admin']")).toBeAttached();
    await expect(select.locator("option[value='producer']")).toBeAttached();
    await expect(select.locator("option[value='worker']")).toBeAttached();
  });
});

test.describe("API Keys CRUD", () => {
  test("create key shows one-time key display", async ({ page }) => {
    await page.goto("/ui/api-keys");
    await page.getByRole("button", { name: "Create Key" }).click();

    const form = page.locator("#create-key-form");
    await form.locator("input[name='name']").fill("test-key-display");
    await form.locator("select[name='role']").selectOption("worker");
    await form.getByRole("button", { name: "Create" }).click();

    // After reload, the one-time key display should be visible.
    await expect(page.locator("#key-created")).toBeVisible({ timeout: 5_000 });
    const keyValue = await page.locator("#created-key-value").textContent();
    expect(keyValue).toBeTruthy();
    expect(keyValue!.length).toBe(64);
  });

  test("created key appears in table", async ({ page }) => {
    // Create a key via API.
    const resp = await fetch(`${BASE}/api/v1/auth/keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ name: "test-key-table", role: "producer" }),
    });
    expect(resp.status).toBe(201);

    await page.goto("/ui/api-keys");
    const row = page.locator("tr", { hasText: "test-key-table" });
    await expect(row).toBeVisible();
    await expect(row.getByText("producer", { exact: true })).toBeVisible();
    await expect(row.getByText("active")).toBeVisible();
  });

  test("delete key removes it from table", async ({ page }) => {
    // Create a key via API.
    const createResp = await fetch(`${BASE}/api/v1/auth/keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify({ name: "test-key-delete", role: "admin" }),
    });
    const { key_hash } = await createResp.json();

    await page.goto("/ui/api-keys");
    await expect(page.getByText("test-key-delete")).toBeVisible();

    // Click delete on this key's row and accept confirm dialog.
    page.on("dialog", (d) => d.accept());
    const row = page.locator("tr", { hasText: "test-key-delete" });
    await row.getByRole("button", { name: "Delete" }).click();

    // After reload, key should be gone.
    await page.waitForLoadState("load");
    await expect(page.getByText("test-key-delete")).not.toBeVisible({ timeout: 5_000 });
  });
});
