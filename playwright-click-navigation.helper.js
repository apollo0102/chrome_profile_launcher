function urlMatches(url, expectedUrl) {
  if (!expectedUrl) {
    return true;
  }

  const href = String(url);

  if (expectedUrl instanceof RegExp) {
    return expectedUrl.test(href);
  }

  if (typeof expectedUrl === "string") {
    return href.includes(expectedUrl);
  }

  if (typeof expectedUrl === "function") {
    return expectedUrl(new URL(href));
  }

  return true;
}

async function clickAndDetectNavigation(page, locator, options = {}) {
  const {
    timeout = 10000,
    waitUntil = "domcontentloaded",
    expectedUrl,
    clickOptions = {},
  } = options;

  const beforeUrl = page.url();

  const popupPromise = page
    .waitForEvent("popup", { timeout })
    .then(async (popup) => {
      await popup.waitForLoadState(waitUntil).catch(() => {});
      return {
        type: "popup",
        page: popup,
        url: popup.url(),
        beforeUrl,
        matchedExpected: urlMatches(popup.url(), expectedUrl),
      };
    })
    .catch(() => null);

  const sameTabPromise = page
    .waitForURL((url) => url.toString() !== beforeUrl, { timeout })
    .then(async () => {
      await page.waitForLoadState(waitUntil).catch(() => {});
      return {
        type: "same-tab",
        page,
        url: page.url(),
        beforeUrl,
        matchedExpected: urlMatches(page.url(), expectedUrl),
      };
    })
    .catch(() => null);

  await locator.click(clickOptions);

  const result = await Promise.race([
    popupPromise,
    sameTabPromise,
    page.waitForTimeout(timeout).then(() => null),
  ]);

  return (
    result || {
      type: "none",
      page,
      url: page.url(),
      beforeUrl,
      matchedExpected: urlMatches(page.url(), expectedUrl),
    }
  );
}

module.exports = {
  clickAndDetectNavigation,
  urlMatches,
};
