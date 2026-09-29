const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Network → Mesh paths against the real rpcd plugin, which reads the configuration the
// tests lay out with h.useConfig (test/fixtures/luci/config/<name>/).

const KEYS = {
  home: 'ckRTxoRCqAhiHEgHPnhfpN6nU5/F2QmMe0nJ2kt7PFc=',
  beach: 'O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=',
  lab: 'hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=',
  hub: 'W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=',
};

const HOSTILE = '<img src=x onerror=window.__xss=1>';

function field(page, option) {
  return page.locator(`[id="widget.cbid.wgpathd.main.${option}"]`);
}

function tab(page, name) {
  return page.locator(`#view .cbi-tabmenu > li[data-tab="${name}"]`);
}

async function openTab(page, name) {
  await tab(page, name).locator('a').click();
  await expect(tab(page, name)).toHaveClass(/\bcbi-tab\b/);
}

function peerRow(page, name) {
  return page.locator(`#view tr[data-key="${KEYS[name]}"]`);
}

function peerField(page, name, title) {
  return peerRow(page, name).getByRole('textbox', { name: title });
}

function checkPanel(page) {
  return page.locator('#view .cbi-section').filter({ has: page.locator('h3', { hasText: /^Configuration check$/ }) });
}

async function saveAndApply(page) {
  await page.locator('#view .cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
}

// From the top, once a tab shown has faded in.
async function shot(page, name) {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(500);
  await h.screenshot(page, name);
}

// LuCI confirms an apply from the page that made it; one left unconfirmed would be
// confirmed by the next page loaded, in the next test.
async function applied(page) {
  await expect(page.getByText('Configuration changes applied.')).toBeVisible({ timeout: 30000 });
}

// The `peer` sections of /etc/config/wgpathd as written on disk, by public key.
function peerSections(file) {
  const out = {};
  for (const block of file.split(/\n(?=config )/)) {
    if (!/^\s*config peer\b/.test(block))
      continue;
    const opts = {};
    for (const m of block.matchAll(/option (\w+) '([^']*)'/g))
      opts[m[1]] = m[2];
    out[opts.public_key] = { relay: opts.relay, tunnel: opts.tunnel };
  }
  return out;
}

test.describe('Network → Mesh paths, a spoke', () => {
  test.beforeEach(async ({ page, request }) => {
    await h.useFixture(request, 'spoke');
    await h.useConfig(request, 'spoke');
    await h.openSettings(page);
  });

  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('shows the committed settings on the General tab, with the spoke\'s fields only', async ({ page }) => {
    await expect(page.locator('[id="cbid.wgpathd.main.enabled"] input[type="checkbox"]')).toBeChecked();
    await expect(field(page, 'role')).toHaveValue('spoke');
    await expect(field(page, 'mode')).toHaveValue('observe');
    await expect(field(page, 'mesh_iface')).toHaveValue('wg_mesh');
    await expect(field(page, 'hub_iface')).toHaveValue('wg_hub');
    await expect(field(page, 'discovery')).toHaveValue('http://10.10.0.1:7780/peers');
    await expect(field(page, 'mesh_iface').locator('option')).toHaveText([ /Please choose/, 'wg_hub', 'wg_mesh' ]);
    for (const option of [ 'read_iface', 'serve_addr', 'serve_port' ])
      await expect(field(page, option)).toBeHidden();
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', '/cgi-bin/luci/admin/status/wgpathd');
    await expect(page.locator('#view .alert-message')).toHaveCount(0);
    await shot(page, 'settings-general');
  });

  test('lists every peer of the mesh interface with its relay endpoint and tunnel address', async ({ page }) => {
    await openTab(page, 'peers');
    await expect(page.locator('#view tr[data-key]')).toHaveCount(4);
    await expect(peerRow(page, 'home').locator('td').first()).toHaveText('homeHome router');
    await expect(peerRow(page, 'home').locator('td').nth(1)).toHaveText('ckRTxoRC…');
    await expect(peerField(page, 'home', 'Relay endpoint')).toHaveValue('10.10.0.12:51820');
    await expect(peerField(page, 'home', 'Tunnel address')).toHaveValue('10.20.0.12');
    await expect(peerRow(page, 'home').locator('td').last()).toHaveText('Yes');
    await expect(peerField(page, 'lab', 'Relay endpoint')).toHaveValue('');
    await expect(peerRow(page, 'lab').locator('td').last()).toHaveText('No');
    await expect(peerRow(page, 'hub').locator('td').last()).toHaveText('No');
    await shot(page, 'settings-peers');
  });

  test('has one field per parameter the daemon reports, its default as placeholder', async ({ page, request }) => {
    const schema = await h.ubus(request, 'wgpathd.config', 'schema');
    await openTab(page, 'timing');
    for (const p of schema.parameters)
      await expect(field(page, p.name), p.name).toHaveAttribute('placeholder', String(p.default));
    await expect(page.locator('#view [data-tab="timing"] .cbi-value')).toHaveCount(schema.parameters.length);
    await expect(field(page, 'n_up')).toHaveValue('3');
    await shot(page, 'settings-timing');
  });

  test('refuses a parameter out of its bounds in the browser', async ({ page }) => {
    await openTab(page, 'timing');
    const cases = [ [ 'cycle', '11', 'Expecting: a number from 1 to 10' ], [ 'n_up', '2.5', 'Expecting: a whole number from 1 to 100' ],
      [ 'tunnel_timeout', '0.05', 'Expecting: a number from 0.1 to 5' ] ];
    for (const [ name, value, message ] of cases) {
      await field(page, name).fill(value);
      await field(page, name).blur();
      await expect(field(page, name), name).toHaveClass(/cbi-input-invalid/);
      await expect(field(page, name), name).toHaveAttribute('data-tooltip', message);
      await field(page, name).fill('');
      await field(page, name).blur();
      await expect(field(page, name), name).not.toHaveClass(/cbi-input-invalid/);
    }
  });

  test('saves and applies a peer\'s new settings to /etc/config/wgpathd, and removes those cleared', async ({ page, request }) => {
    await openTab(page, 'peers');
    await peerField(page, 'lab', 'Relay endpoint').fill('10.10.0.14:51820');
    await peerField(page, 'lab', 'Tunnel address').fill('10.20.0.14');
    await expect(peerRow(page, 'lab').locator('td').last()).toHaveText('Yes');
    await peerField(page, 'beach', 'Relay endpoint').fill('');
    await peerField(page, 'beach', 'Tunnel address').fill('');
    await saveAndApply(page);
    await applied(page);

    expect(peerSections(await h.readConfig(request, 'wgpathd'))).toEqual({
      [KEYS.home]: { relay: '10.10.0.12:51820', tunnel: '10.20.0.12' },
      [KEYS.lab]: { relay: '10.10.0.14:51820', tunnel: '10.20.0.14' },
    });
  });

  test('switches to the hub\'s fields, without the Peers tab, when the role changes', async ({ page }) => {
    await field(page, 'role').selectOption('hub');
    for (const option of [ 'read_iface', 'serve_addr', 'serve_port' ])
      await expect(field(page, option)).toBeVisible();
    for (const option of [ 'mode', 'mesh_iface', 'hub_iface', 'discovery' ])
      await expect(field(page, option)).toBeHidden();
    await expect(tab(page, 'peers')).toBeHidden();
    await expect(tab(page, 'timing')).toBeVisible();
  });

  test('marks a field the check fails and opens its tab', async ({ page }) => {
    await openTab(page, 'timing');
    await field(page, 'trial_window').fill('4');
    await openTab(page, 'general');
    await page.getByRole('button', { name: 'Check configuration' }).click();

    const panel = checkPanel(page);
    await expect(panel.locator('tr').filter({ has: page.locator('.label', { hasText: 'Fail' }) })).toHaveText(
      [ /^Fail\s*Direct test time: must be longer than cycle \+ tunnel_timeout \(4\)$/ ]);
    await expect(tab(page, 'timing')).toHaveClass(/\bcbi-tab\b/);
    await expect(field(page, 'trial_window')).toHaveClass(/cbi-input-invalid/);
    await expect(tab(page, 'timing')).toHaveAttribute('data-errors', '1');

    await field(page, 'trial_window').fill('9');
    await field(page, 'trial_window').blur();
    await expect(field(page, 'trial_window')).not.toHaveClass(/cbi-input-invalid/);
  });

  test('marks the peer field the check fails, and says in words what it found', async ({ page }) => {
    await openTab(page, 'peers');
    await peerField(page, 'lab', 'Relay endpoint').fill('10.10.0.14:0');
    await peerField(page, 'lab', 'Tunnel address').fill('10.20.0.14');
    await openTab(page, 'general');
    await page.getByRole('button', { name: 'Check configuration' }).click();

    await expect(tab(page, 'peers')).toHaveClass(/\bcbi-tab\b/);
    await expect(peerField(page, 'lab', 'Relay endpoint')).toHaveClass(/cbi-input-invalid/);
    await expect(peerField(page, 'lab', 'Tunnel address')).not.toHaveClass(/cbi-input-invalid/);
    await expect(checkPanel(page).locator('tr')).toHaveText([
      /^OK\s*Spoke in observe mode: 2 peers steered, 2 peers not steered$/,
      /^Warn\s*The route to the hub at 10\.10\.0\.1 could not be looked up: /,
      /^Warn\s*home: the route to its relay endpoint could not be looked up, tried again every check: /,
      /^Warn\s*beach: the route to its relay endpoint could not be looked up, tried again every check: /,
      /^Fail\s*lab: not steered\. The relay endpoint is not valid$/,
      /^Skip\s*hub: not steered\. No relay endpoint or tunnel address set$/,
    ]);
    expect(await h.text(checkPanel(page))).not.toMatch(/\b(config|peer) \S+:|wgpathd_|not configured/);
    await shot(page, 'settings-check');
  });

  test('applies nothing when the check fails, and says why', async ({ page, request }) => {
    const before = await h.readConfig(request, 'wgpathd');
    await openTab(page, 'timing');
    await field(page, 'trial_window').fill('4');
    await saveAndApply(page);

    await expect(checkPanel(page).locator('.alert-message')).toHaveText(
      'Nothing was saved or applied: the check found problems, which wgpathd would refuse or leave unsteered. Fix the fields it marks, then try again.');
    await page.waitForTimeout(1000);
    expect(await h.readConfig(request, 'wgpathd')).toBe(before);
    await expect(page.locator('#modal_overlay .modal')).toBeHidden();
    await shot(page, 'settings-refused');
  });
});

test.describe('Network → Mesh paths, other states', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
    await h.useFixture(request, 'spoke');
  });

  test('works while the service is not running, and says so', async ({ page, request }) => {
    await h.useFixture(request, 'none');
    await h.useConfig(request, 'spoke');
    await h.openSettings(page);
    await expect(page.locator('#view .alert-message.warning')).toHaveText(
      'The wgpathd service is not running. Its settings can still be changed and checked here.');
    await openTab(page, 'peers');
    await expect(page.locator('#view tr[data-key]')).toHaveCount(4);
    await page.getByRole('button', { name: 'Check configuration' }).click();
    await expect(checkPanel(page).locator('tr').first()).toHaveText(/^OK\s*Spoke in observe mode/);
    await shot(page, 'settings-not-running');
  });

  test('says when the router has no WireGuard interface', async ({ page, request }) => {
    await h.useConfig(request, 'no-wireguard');
    await h.openSettings(page);
    await expect(page.locator('#view .alert-message.warning')).toHaveText(
      'This router has no WireGuard interface yet. Set up the mesh and hub interfaces under Network → Interfaces first.');
    await expect(field(page, 'mesh_iface').locator('option')).toHaveText([ /Please choose/ ]);
    await shot(page, 'settings-no-wireguard');
  });

  test('says when the mesh interface has no peers', async ({ page, request }) => {
    await h.useConfig(request, 'no-peers');
    await h.openSettings(page);
    await openTab(page, 'peers');
    await expect(page.locator('#view [data-tab="peers"] tr.placeholder')).toHaveText(
      'wg_mesh has no peers. Add them to the WireGuard interface under Network → Interfaces.');
  });

  test('shows a hub\'s fields and no Peers tab', async ({ page, request }) => {
    await h.useFixture(request, 'hub');
    await h.useConfig(request, 'hub');
    await h.openSettings(page);
    await expect(field(page, 'role')).toHaveValue('hub');
    await expect(field(page, 'read_iface')).toHaveValue('wg_mesh');
    await expect(field(page, 'serve_addr')).toHaveValue('10.20.0.10');
    await expect(field(page, 'serve_port')).toHaveValue('7780');
    await expect(tab(page, 'peers')).toBeHidden();
    await shot(page, 'settings-hub');
  });

  test('lists the peers of another mesh interface when it is chosen', async ({ page, request }) => {
    await h.useConfig(request, 'spoke');
    await h.openSettings(page);
    await field(page, 'mesh_iface').selectOption('wg_hub');
    await openTab(page, 'peers');
    await expect(page.locator('#view tr[data-key]')).toHaveCount(1);
    await expect(peerRow(page, 'hub').locator('td').first()).toHaveText('hub_transit');
  });
});

test.describe('Network → Mesh paths, text from the router', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('shows a hostile peer description and check message as text', async ({ page, request }) => {
    await h.useConfig(request, 'hostile');
    await h.openSettings(page);
    await openTab(page, 'peers');
    await expect(peerRow(page, 'beach').locator('small')).toHaveText(HOSTILE);
    await page.getByRole('button', { name: 'Check configuration' }).click();
    await expect(checkPanel(page).getByText(HOSTILE)).toBeVisible();
    await page.waitForTimeout(500);
    expect(await page.evaluate(() => window.__xss)).toBeUndefined();
    await expect(page.locator('img[src="x"]')).toHaveCount(0);
  });
});

test.describe('Network → Mesh paths, with the app\'s ACL alone', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('reads, checks, saves and applies the settings', async ({ page, request }) => {
    await h.useConfig(request, 'spoke');
    await h.openSettings(page, h.APP_USER);
    await openTab(page, 'peers');
    await expect(page.locator('#view tr[data-key]')).toHaveCount(4);
    await peerField(page, 'lab', 'Relay endpoint').fill('10.10.0.14:51820');
    await peerField(page, 'lab', 'Tunnel address').fill('10.20.0.14');
    await openTab(page, 'timing');
    await expect(field(page, 'cycle')).toHaveAttribute('placeholder', '3');
    await page.getByRole('button', { name: 'Check configuration' }).click();
    await expect(checkPanel(page).locator('tr').first()).toHaveText(/^OK\s*Spoke in observe mode: 3 peers steered/);
    await saveAndApply(page);
    await applied(page);
    expect(peerSections(await h.readConfig(request, 'wgpathd'))[KEYS.lab]).toEqual({ relay: '10.10.0.14:51820', tunnel: '10.20.0.14' });
  });

  test('is denied the network configuration, which holds the private keys', async ({ page, request }) => {
    await h.useConfig(request, 'spoke');
    await h.openSettings(page, h.APP_USER);
    const denied = await page.evaluate(() => L.require('uci').then((uci) => uci.load('network')).then(
      () => 'loaded', (err) => err.message));
    expect(denied).toMatch(/Permission denied/);

    const login = await h.call(request, '00000000000000000000000000000000', 'session', 'login', h.APP_USER);
    await expect(h.call(request, login.ubus_rpc_session, 'uci', 'get', { config: 'network' })).rejects.toThrow(/"result":\[6\]/);
    const peers = await h.call(request, login.ubus_rpc_session, 'wgpathd.config', 'peers', {});
    expect(JSON.stringify(peers)).not.toMatch(/private_key|preshared_key|cHJpdmF0|cHJlc2hhcmVk|endpoint|allowed_ips/);
  });
});
