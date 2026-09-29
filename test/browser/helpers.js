'use strict';

const { expect } = require('@playwright/test');
const path = require('path');

const PASSWORD = 'admin';
const SCREENSHOTS = path.join(__dirname, '..', 'results', 'screenshots');

// The state names and reasons of the ubus reply, which the pages must put in words.
const INTERNAL_NAMES = /\b(RELAY|TRIALING|DIRECT|trial_start|trial_ok|trial_timeout|demoted|observe_mode|roam_adopted)\b/;

let session = null;

// A ubus call over uhttpd's JSON-RPC endpoint, as root: switches fixtures and themes.
async function ubus(request, object, method, params) {
  if (session == null) {
    const login = await call(request, '00000000000000000000000000000000', 'session', 'login',
      { username: 'root', password: PASSWORD });
    session = login.ubus_rpc_session;
  }
  return call(request, session, object, method, params);
}

async function call(request, sid, object, method, params) {
  const res = await request.post('/ubus/', {
    data: { jsonrpc: '2.0', id: 1, method: 'call', params: [sid, object, method, params ?? {}] },
  });
  const body = await res.json();
  if (body.error || body.result[0] !== 0)
    throw new Error(`ubus ${object} ${method}: ${JSON.stringify(body)}`);
  return body.result[1];
}

// Makes the fake wgpathd answer test/fixtures/luci/<name>.json; `none` withdraws it.
async function useFixture(request, name) {
  const res = await ubus(request, 'wgpathd.fixture', 'use', { name });
  expect(res.ok, `fixture ${name}`).toBe(true);
}

// Themes are named after their directory under /luci-static.
async function useTheme(request, theme) {
  await ubus(request, 'uci', 'set', { config: 'luci', section: 'main', values: { mediaurlbase: `/luci-static/${theme}` } });
  await ubus(request, 'uci', 'commit', { config: 'luci' });
}

// Posts LuCI's login form through the page's own request context, which shares the
// browser's cookies, so the page then opens logged in.
async function open(page, route) {
  const login = await page.request.post('/cgi-bin/luci/', {
    form: { luci_username: 'root', luci_password: PASSWORD },
    maxRedirects: 0,
  });
  expect(login.status(), 'LuCI login').toBe(302);
  await page.goto(`/cgi-bin/luci/${route}`);
  await page.locator('#view').waitFor();
  await expect(page.locator('#view .spinning')).toHaveCount(0);
}

async function openStatus(page) {
  await open(page, 'admin/status/wgpathd');
  await expect(page.locator('#view h2', { hasText: 'Mesh paths' })).toBeVisible();
}

async function openOverview(page) {
  await open(page, 'admin/status/overview');
  await expect(page.locator('.cbi-section h3', { hasText: 'System' })).toBeVisible();
}

// A section of the Status page by its heading.
function section(page, title) {
  return page.locator('#view .cbi-section').filter({ has: page.locator('h3', { hasText: new RegExp(`^${title}$`) }) });
}

function peerRow(page, name) {
  return section(page, 'Peers').locator('tr').filter({ has: page.locator('td strong', { hasText: new RegExp(`^${name}$`) }) });
}

// The details row follows its peer's row.
function detailsRow(page, name) {
  return peerRow(page, name).locator('xpath=following-sibling::tr[1]');
}

// The pieces of the strip that ends at `peer`: nodes' texts and segments' border
// styles, in order. It is found and read in one evaluation under #view, which the page
// keeps while its poll replaces everything inside: a strip found in one step and read
// in the next may be detached by then, and a detached node has no computed style.
async function strip(page, peer) {
  return page.locator('#view').evaluate((view, peer) => {
    const path = Array.from(view.querySelectorAll('.wgpathd-path')).find((p) => p.lastElementChild?.textContent === peer);
    return path ? Array.from(path.children).map((s) =>
      s.textContent !== '' ? s.textContent : getComputedStyle(s).borderTopStyle) : null;
  }, peer);
}

// Opens every details row; each button's text changes as it is clicked.
async function expandAll(page) {
  const closed = page.locator('#view button[aria-expanded="false"]');
  while (await closed.count())
    await closed.first().click();
}

// The text as written, before a theme's text-transform (labels are upper case in some).
async function text(locator) {
  return locator.evaluate((el) => el.textContent);
}

// A whole page, or one section of it given as a locator.
async function screenshot(target, name) {
  const file = path.join(SCREENSHOTS, `${name}.png`);
  await (target.url ? target.screenshot({ path: file, fullPage: true }) : target.screenshot({ path: file }));
}

module.exports = {
  INTERNAL_NAMES, ubus, useFixture, useTheme, open, openStatus, openOverview, section, peerRow, detailsRow, strip,
  expandAll, text, screenshot,
};
