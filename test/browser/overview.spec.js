const { test, expect } = require('@playwright/test');
const h = require('./helpers');

function meshPaths(page) {
  return page.locator('.cbi-section').filter({ has: page.locator('h3', { hasText: /^Mesh paths/ }) });
}

test.describe('Status → Overview, Mesh paths section', () => {
  test('shows each steered peer with its path strip, state and one short line', async ({ page, request }) => {
    await h.useFixture(request, 'spoke');
    await h.openOverview(page);
    const mesh = meshPaths(page);
    await expect(mesh.locator('tr:not(.table-titles)')).toHaveText([
      /^beach\s*.*Via hub next direct try in 4 min$/,
      /^home\s*.*Direct for 2 h 14 min$/,
      /^lab\s*.*Testing direct test ends in 5 s$/,
    ]);
    expect(await h.strip(page, 'beach')).toEqual([ 'office', 'dashed', 'hub', 'dashed', 'beach' ]);
    await expect(mesh.getByRole('link', { name: 'Details' })).toHaveAttribute('href', '/cgi-bin/luci/admin/status/wgpathd');
    expect(await h.text(mesh)).not.toMatch(h.INTERNAL_NAMES);
    await h.screenshot(mesh, 'overview');
  });

  test('says which peers would test direct in observe mode', async ({ page, request }) => {
    await h.useFixture(request, 'observe');
    await h.openOverview(page);
    await expect(meshPaths(page).locator('tr', { hasText: 'home' })).toContainText('Via hub would test direct');
  });

  for (const fixture of [ 'none', 'no-peers', 'hub' ]) {
    test(`stays hidden without steered peers (${fixture})`, async ({ page, request }) => {
      await h.useFixture(request, fixture);
      await h.openOverview(page);
      await expect(page.locator('.cbi-section h3', { hasText: /^Memory/ })).toBeVisible();
      await expect(meshPaths(page)).toBeHidden();
    });
  }
});
