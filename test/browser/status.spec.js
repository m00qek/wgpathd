const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Fixture times are relative to their frozen `now`, 1790456500 (21:01:40 UTC).

test.describe('Status → Mesh paths, spoke in steer mode', () => {
  test.beforeEach(async ({ page, request }) => {
    await h.useFixture(request, 'spoke');
    await h.openStatus(page);
  });

  test('describes the service: mode, interfaces and peer list age', async ({ page }) => {
    const service = h.section(page, 'Service');
    await expect(service.locator('tr')).toHaveText([
      /^Mode\s*Steer: switches paths automatically$/,
      /^Mesh\s*wg_mesh, relaying through wg_hub$/,
      /^Peer list\s*Updated 12 s ago from http:\/\/10\.10\.0\.1:7780\/peers$/,
    ]);
    await expect(page.locator('#view .alert-message')).toHaveCount(0);
  });

  test('shows each peer with its state, path strip, endpoint, age and switches', async ({ page }) => {
    const home = h.peerRow(page, 'home');
    await expect(home.locator('td')).toHaveText(
      [ 'home', /^Direct/, '[2001:db8:40::20]:51820', '2 h 14 min', '1', 'Show details' ]);
    expect(await h.strip(page, 'home')).toEqual([ 'office', 'solid', 'home' ]);

    const beach = h.peerRow(page, 'beach');
    await expect(beach.locator('td')).toHaveText(
      [ 'beach', /^Via hub/, '10.10.0.13:51820', '4 min', '6', 'Show details' ]);
    expect(await h.strip(page, 'beach')).toEqual([ 'office', 'dashed', 'hub', 'dashed', 'beach' ]);

    const lab = h.peerRow(page, 'lab');
    await expect(lab.locator('td')).toHaveText(
      [ 'lab', /^Testing direct/, '[2001:db8:77::1]:51820', '3 s', '2', 'Show details' ]);
    expect(await h.strip(page, 'lab')).toEqual([ 'office', 'dotted', 'lab' ]);
  });

  test('labels the states with the theme\'s label classes', async ({ page }) => {
    await expect(h.peerRow(page, 'home').locator('.label')).toHaveClass('label success');
    await expect(h.peerRow(page, 'beach').locator('.label')).toHaveClass('label warning');
    await expect(h.peerRow(page, 'lab').locator('.label')).toHaveClass('label notice');
  });

  test('greys out an unmanaged peer and says why it is not steered', async ({ page }) => {
    const hub = h.peerRow(page, 'hub');
    await expect(hub.locator('td')).toHaveText([ 'hub', 'Not steered', 'No relay endpoint set' ]);
    await expect(hub).toHaveCSS('opacity', '0.6');
  });

  test('expands and collapses the details of a peer on the hub path', async ({ page }) => {
    const details = h.detailsRow(page, 'beach');
    const button = h.peerRow(page, 'beach').getByRole('button');
    await expect(details).toBeHidden();
    await expect(button).toHaveAttribute('aria-expanded', 'false');

    await button.click();
    await expect(details).toBeVisible();
    await expect(button).toHaveText('Hide details');
    await expect(button).toHaveAttribute('aria-expanded', 'true');
    await expect(details.locator('td > div > div')).toHaveText([
      'Direct address last tried[2001:db8:90::5]:51820',
      'Direct address the hub publishes[2001:db8:90::5]:51820',
      'Why it uses the hub2 checks in a row got no answer over the direct path',
      'Next direct tryIn 4 min, then waits longer after each failure, up to 15 min',
      'Answers that came through the hub0',
    ]);
    await h.screenshot(page, 'status-spoke');

    await button.click();
    await expect(details).toBeHidden();
    await expect(button).toHaveText('Show details');
  });

  test('details of a peer testing direct say when the test ends', async ({ page }) => {
    await h.peerRow(page, 'lab').getByRole('button').click();
    await expect(h.detailsRow(page, 'lab').locator('td > div > div')).toHaveText([
      'Direct address under test[2001:db8:77::1]:51820',
      'Test ends in5 s',
      'Answers that came through the hub1',
    ]);
  });

  test('details of a direct peer count the checks it may still miss', async ({ page }) => {
    await h.peerRow(page, 'home').getByRole('button').click();
    await expect(h.detailsRow(page, 'home').locator('td > div > div')).toHaveText([
      'Direct address[2001:db8:40::20]:51820',
      'Checks without an answer0 of 2 before it goes back to the hub',
      'Answers that came through the hub0',
    ]);
  });

  test('lists recent changes in words, at the router\'s clock time', async ({ page }) => {
    const changes = h.section(page, 'Recent changes');
    await expect(changes.locator('.cbi-section-descr')).toHaveText(
      'Kept in memory since the service started, most recent first. Every change is also in the system log.');
    await expect(changes.locator('.cbi-section-descr a')).toHaveAttribute('href', '/cgi-bin/luci/admin/status/logs');
    await expect(changes.locator('tr:not(.table-titles)')).toHaveText([
      /^21:01:37 \(3 s ago\)\s*lab\s*Testing direct, was via hub$/,
      /^20:57:40 \(4 min ago\)\s*beach\s*Via hub, was direct: 2 checks in a row got no answer$/,
      /^20:36:40 \(25 min ago\)\s*beach\s*Direct, the test passed$/,
      /^18:47:40 \(2 h 14 min ago\)\s*home\s*Direct, the test passed$/,
    ]);
  });

  test('points to the settings page', async ({ page }) => {
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', '/cgi-bin/luci/admin/network/wgpathd');
  });

  test('refreshes by itself and keeps open details open', async ({ page, request }) => {
    await h.peerRow(page, 'beach').getByRole('button').click();
    await h.useFixture(request, 'stale');
    await expect(page.locator('#view .alert-message.warning')).toBeVisible({ timeout: 15000 });
    await expect(h.detailsRow(page, 'beach')).toBeVisible();

    await h.useFixture(request, 'relay');
    await expect(h.peerRow(page, 'lab').locator('.label')).toHaveText('Via hub', { timeout: 15000 });
  });
});

test.describe('Status → Mesh paths, peers on the hub path', () => {
  test.beforeEach(async ({ page, request }) => {
    await h.useFixture(request, 'relay');
    await h.openStatus(page);
    for (const name of [ 'beach', 'home', 'lab' ])
      await h.peerRow(page, name).getByRole('button').click();
  });

  test('says why each uses the hub and when it tries direct next', async ({ page }) => {
    await expect(h.detailsRow(page, 'beach').locator('td > div > div')).toHaveText([
      'Direct address last tried[2001:db8:90::5]:51820',
      'Direct address the hub publishes[2001:db8:90::5]:51820',
      'Why it uses the hubThe direct test got no answer within 8 s',
      'Next direct tryIn 10 s, then waits longer after each failure, up to 15 min',
      'Answers that came through the hub0',
    ]);
    await expect(h.detailsRow(page, 'home').locator('td > div > div')).toHaveText([
      'Direct address last triedNone yet',
      'Direct address the hub publishesNone',
      'Why it uses the hubIt has used the hub since the service started',
      'Next direct tryOnce the hub publishes a direct address for this peer',
      'Answers that came through the hub0',
    ]);
    await expect(h.detailsRow(page, 'lab').locator('td > div > div').nth(3)).toHaveText(
      'Next direct tryAfter 5 answered checks in a row over the direct address; 2 so far');
  });

  test('words a failed test in the recent changes', async ({ page }) => {
    await expect(h.section(page, 'Recent changes').locator('tr:not(.table-titles) td:last-child')).toHaveText([
      'Via hub, the direct test got no answer within 8 s',
      'Testing direct, was via hub',
    ]);
  });
});

test.describe('Status → Mesh paths, other service states', () => {
  test('observe mode says so and shows which peers would test direct', async ({ page, request }) => {
    await h.useFixture(request, 'observe');
    await h.openStatus(page);
    await expect(page.locator('#view .alert-message.notice')).toContainText(
      'Observe mode: wgpathd checks the direct paths and logs what it would do, but keeps every peer on the hub path.');
    await expect(h.section(page, 'Service').locator('tr').first()).toHaveText(
      /Observe: watches the paths but never switches them/);
    await expect(h.peerRow(page, 'home').locator('.label')).toHaveText([ 'Via hub', 'Would test direct' ]);
    await expect(h.peerRow(page, 'beach').locator('.label')).toHaveText([ 'Via hub' ]);

    await h.peerRow(page, 'home').getByRole('button').click();
    await h.peerRow(page, 'beach').getByRole('button').click();
    await expect(h.detailsRow(page, 'home').locator('td > div > div').nth(2)).toHaveText(
      'Why it uses the hubThe service was switched to observe mode');
    await expect(h.detailsRow(page, 'home').locator('td > div > div').nth(3)).toHaveText(
      'Would test directYes, steer mode would test the direct path now');
    await expect(h.detailsRow(page, 'beach').locator('td > div > div').nth(3)).toHaveText(
      'Would test directNot yet: 2 of 5 checks answered over the direct address');
    await expect(h.section(page, 'Recent changes').locator('tr:not(.table-titles) td:last-child')).toHaveText(
      [ 'Via hub, the service was switched to observe mode' ]);
    await h.screenshot(page, 'status-observe');
  });

  test('a failing peer list is flagged with the age of the last good one', async ({ page, request }) => {
    await h.useFixture(request, 'stale');
    await h.openStatus(page);
    await expect(page.locator('#view .alert-message.warning')).toHaveText(
      'The peer list could not be updated from the hub. Direct tries use the addresses from the last good list, 25 min old.');
    await expect(h.section(page, 'Service').locator('tr').nth(2)).toHaveText(
      /^Peer list\s*Update failed; the last good list is 25 min old\. From http:\/\/10\.10\.0\.1:7780\/peers$/);
    await h.screenshot(page, 'status-stale');
  });

  test('no steered peer: says how to add one and lists the others with their reasons', async ({ page, request }) => {
    await h.useFixture(request, 'no-peers');
    await h.openStatus(page);
    await expect(page.locator('#view .alert-message.warning')).toHaveText(
      'The peer list has not been fetched from the hub yet. Until it is, direct tries use the addresses saved by an earlier run, if any.');
    await expect(h.section(page, 'Service').locator('tr').nth(2)).toHaveText(
      /^Peer list\s*Not fetched yet, from http:\/\/10\.10\.0\.1:7780\/peers$/);
    const peers = h.section(page, 'Peers');
    await expect(peers.locator('tr.placeholder')).toHaveText(
      'No peer is steered yet. Give peers a relay endpoint and a tunnel address under Network → Mesh paths.');
    await expect(h.peerRow(page, 'garage').locator('td').last()).toHaveText('The relay endpoint is routed into wg_mesh');
    await expect(h.peerRow(page, 'attic').locator('td').last()).toHaveText(
      'The route to the relay endpoint could not be looked up, tried again every check: ROUTE_LOOKUP_FAILED (10.10.0.19: Network unreachable)');
    await expect(h.section(page, 'Recent changes').locator('tr.placeholder')).toHaveText('No changes since the service started.');
    await h.screenshot(page, 'status-no-peers');
  });

  test('not running: says so and points to the settings', async ({ page, request }) => {
    await h.useFixture(request, 'none');
    await h.openStatus(page);
    const alert = page.locator('#view .alert-message.warning');
    await expect(alert).toHaveText(
      'The wgpathd service is not running.Enable it and check its settings under Network → Mesh paths.');
    await expect(alert.locator('a')).toHaveAttribute('href', '/cgi-bin/luci/admin/network/wgpathd');
    await expect(page.locator('#view .cbi-section')).toHaveCount(0);
    await h.screenshot(page, 'status-not-running');
  });

  test('comes back when the service starts', async ({ page, request }) => {
    await h.useFixture(request, 'none');
    await h.openStatus(page);
    await h.useFixture(request, 'spoke');
    await expect(h.peerRow(page, 'home')).toBeVisible({ timeout: 15000 });
  });
});

test.describe('Status → Mesh paths, hub', () => {
  test('lists the published peers by name, with how long ago each was heard', async ({ page, request }) => {
    await h.useFixture(request, 'hub');
    await h.openStatus(page);
    await expect(page.locator('#view p').first()).toHaveText(/^This router is the hub\./);
    const published = h.section(page, 'Published peers');
    await expect(published.locator('.cbi-section-descr')).toHaveText(/^Spokes fetch this list from http:\/\/10\.10\.0\.1:7780\/peers\./);
    await expect(published.locator('tr:not(.table-titles)')).toHaveText([
      /^beach\s*O0LYRo\/R…\s*\[2001:db8:90::5\]:51820\s*1 min ago$/,
      /^home\s*ckRTxoRC…\s*\[2001:db8:40::20\]:51820\s*21 s ago$/,
      /^lab\s*hQrcvDZE…\s*\[2001:db8:77::1\]:51820\s*11 h ago$/,
      /^office\s*vpW\+HezC…\s*\[2001:db8:10::20\]:51820\s*8 s ago$/,
      /^Unknown\s*Bf7nK2pQ…\s*\[2001:db8:aa::9\]:51820\s*Never$/,
    ]);
    await expect(published.locator('tr', { hasText: 'lab' })).toHaveCSS('opacity', '0.6');
    await expect(published.locator('tr', { hasText: 'office' })).toHaveCSS('opacity', '1');
    await expect(h.section(page, 'Peers')).toHaveCount(0);
    await h.screenshot(page, 'status-hub');
  });
});

test.describe('Status → Mesh paths, words only', () => {
  for (const fixture of [ 'spoke', 'relay', 'observe', 'stale', 'no-peers', 'hub' ]) {
    test(`shows no internal state or reason name (${fixture})`, async ({ page, request }) => {
      await h.useFixture(request, fixture);
      await h.openStatus(page);
      await h.expandAll(page);
      expect(await h.text(page.locator('#view'))).not.toMatch(h.INTERNAL_NAMES);
    });
  }
});
