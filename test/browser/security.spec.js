const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Every free-text field of these fixtures is HOSTILE (test/fixtures/luci/hostile*.json).
const HOSTILE = '<img src=x onerror=window.__xss=1>';

// Markup from the reply would make an <img src="x">, whose failed load runs onerror.
async function expectInert(page) {
  await page.waitForTimeout(500);
  expect(await page.evaluate(() => window.__xss)).toBeUndefined();
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
}

test.describe('Status data is shown as text, never markup', () => {
  for (const fixture of [ 'hostile', 'hostile-role', 'hostile-hub' ]) {
    test(`on the Status page (${fixture})`, async ({ page, request }) => {
      await h.useFixture(request, fixture);
      await h.openStatus(page);
      await h.expandAll(page);
      await expectInert(page);
      await expect(page.locator('#view').getByText(HOSTILE).first()).toBeVisible();
      if (fixture === 'hostile')
        await h.screenshot(page, 'status-hostile');
    });
  }

  test('in the Overview section', async ({ page, request }) => {
    await h.useFixture(request, 'hostile');
    await h.openOverview(page);
    await expectInert(page);
    await expect(page.locator('#view').getByText(HOSTILE).first()).toBeVisible();
  });
});
