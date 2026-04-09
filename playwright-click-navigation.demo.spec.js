const path = require("path");
const { pathToFileURL } = require("url");
const { test, expect } = require("@playwright/test");
const {
  clickAndDetectNavigation,
} = require("./playwright-click-navigation.helper");

const demoIndexUrl = pathToFileURL(
  path.join(__dirname, "playwright-demo", "index.html")
).href;

test("detects same-tab navigation on a local demo page", async ({ page }) => {
  await page.goto(demoIndexUrl);

  const result = await clickAndDetectNavigation(
    page,
    page.locator("#same-tab-link"),
    { expectedUrl: /next\.html$/ }
  );

  expect(result.type).toBe("same-tab");
  expect(result.matchedExpected).toBe(true);
  await expect(page.locator("#message")).toHaveText("Navigation completed.");
});

test("detects popup navigation on a local demo page", async ({ page }) => {
  await page.goto(demoIndexUrl);

  const result = await clickAndDetectNavigation(
    page,
    page.locator("#popup-link"),
    { expectedUrl: /mode=popup/ }
  );

  expect(result.type).toBe("popup");
  expect(result.matchedExpected).toBe(true);
  await expect(result.page.locator("#message")).toHaveText("Navigation completed.");
});

test("reports no navigation for an inline UI action", async ({ page }) => {
  await page.goto(demoIndexUrl);

  const result = await clickAndDetectNavigation(
    page,
    page.locator("#inline-action"),
    { timeout: 1000 }
  );

  expect(result.type).toBe("none");
  await expect(page.locator("#inline-status")).toHaveText("Inline action ran");
});
