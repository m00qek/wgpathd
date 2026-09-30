const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// The path strip has no colours of its own: segments and nodes are drawn in the
// text colour (currentColor). In every theme and scheme they must stand out from
// the background behind them. The Fail label of the configuration check must be red.
const THEMES = [
  { theme: 'bootstrap', scheme: 'light' },
  { theme: 'bootstrap', scheme: 'dark' },
  { theme: 'bootstrap-dark', scheme: 'light' },
  { theme: 'openwrt2020', scheme: 'light' },
  { theme: 'material', scheme: 'light' },
];

// WCAG's minimum contrast for graphical objects.
const MIN_CONTRAST = 3;

const LAB = 'hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=';

// The colours of the path strips and the labels in the view, as [ r, g, b ] painted
// over what is behind them. One synchronous pass over the view, which a refresh
// cannot replace halfway.
function viewColours(view) {
  // Any computed colour (rgb(), oklch(), color(srgb ...) in newer themes) as [ r, g, b, a ],
  // a from 0 to 1, as a canvas paints it.
  const ctx = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  const rgba = (css) => {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = css;
    ctx.fillRect(0, 0, 1, 1);
    const [ r, g, b, a ] = ctx.getImageData(0, 0, 1, 1).data;
    return [ r, g, b, a / 255 ];
  };
  // A translucent colour as it shows over `under`.
  const over = (css, under) => {
    const [ r, g, b, a ] = rgba(css);
    return [ r, g, b ].map((c, i) => a * c + (1 - a) * under[i]);
  };
  const background = (el) => {
    const layers = [];
    for (let e = el; e; e = e.parentElement) {
      const bg = getComputedStyle(e).backgroundColor;
      const alpha = rgba(bg)[3];
      if (alpha > 0)
        layers.push(bg);
      if (alpha === 1)
        break;
    }
    return layers.reverse().reduce((under, bg) => over(bg, under), [ 255, 255, 255 ]);
  };

  return {
    strips: Array.from(view.querySelectorAll('.wgpathd-path')).map((path) => {
      const backdrop = background(path.parentElement);
      const spans = Array.from(path.children);
      return {
        peer: spans[spans.length - 1].textContent,
        backdrop: backdrop,
        segments: spans.filter((s) => s.textContent === '').map((s) => over(getComputedStyle(s).borderTopColor, backdrop)),
        hub: spans.filter((s) => s.textContent === 'hub').map((s) => over(getComputedStyle(s).backgroundColor, backdrop)),
      };
    }),
    labels: Array.from(view.querySelectorAll('.label')).map((label) => {
      const fill = background(label);
      return { text: label.textContent, fill: fill, color: over(getComputedStyle(label).color, fill) };
    }),
  };
}

function luminance([ r, g, b ]) {
  const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

function contrast(a, b) {
  const [ l1, l2 ] = [ luminance(a), luminance(b) ].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

function reddish([ r, g, b ]) {
  return r > 2 * g && r > 2 * b;
}

test.describe('Path strip across themes', () => {
  test.afterEach(async ({ request }) => {
    await h.useTheme(request, 'bootstrap');
  });

  for (const { theme, scheme } of THEMES) {
    test(`stays visible in ${theme} (${scheme} scheme)`, async ({ page, request }) => {
      await h.useFixture(request, 'spoke');
      await h.useTheme(request, theme);
      await page.emulateMedia({ colorScheme: scheme });
      await h.openStatus(page);
      expect(await page.locator('link[rel="stylesheet"]').first().getAttribute('href')).toContain(`/luci-static/${theme}/`);

      const { strips } = await page.locator('#view').evaluate(viewColours);
      expect(strips.map((c) => c.peer)).toEqual([ 'beach', 'home', 'lab' ]);
      for (const c of strips)
        for (const colour of c.segments.concat(c.hub))
          expect(contrast(colour, c.backdrop), `${c.peer} in ${theme}`).toBeGreaterThanOrEqual(MIN_CONTRAST);

      await h.peerRow(page, 'beach').getByRole('button').click();
      await h.screenshot(page, `theme-${theme}-${scheme}`);
    });
  }
});

test.describe('Configuration check across themes', () => {
  test.afterEach(async ({ request }) => {
    await h.useTheme(request, 'bootstrap');
    await h.useConfig(request, 'default');
  });

  for (const { theme, scheme } of THEMES) {
    test(`shows Fail in red in ${theme} (${scheme} scheme)`, async ({ page, request }) => {
      await h.useFixture(request, 'spoke');
      await h.useConfig(request, 'spoke');
      await h.ubus(request, 'uci', 'add', {
        config: 'wgpathd', type: 'peer', values: { public_key: LAB, relay: '10.10.0.14:0', tunnel: '10.20.0.14' },
      });
      await h.ubus(request, 'uci', 'commit', { config: 'wgpathd' });
      await h.useTheme(request, theme);
      await page.emulateMedia({ colorScheme: scheme });
      await h.openSettings(page);
      await page.getByRole('button', { name: 'Check configuration' }).click();
      const panel = h.section(page, 'Configuration check');
      await expect(panel.locator('.label')).toHaveText([ 'OK', 'Warn', 'Warn', 'Warn', 'Fail', 'Skip', 'OK', 'OK', 'OK' ]);

      const { labels } = await page.locator('#view').evaluate(viewColours);
      const [ fail ] = labels.filter((l) => l.text === 'Fail');
      expect(reddish(fail.fill), `Fail is ${fail.fill}`).toBe(true);
      expect(contrast(fail.color, fail.fill), 'Fail text').toBeGreaterThanOrEqual(MIN_CONTRAST);
      // openwrt2020 paints its warning labels red as well.
      if (theme !== 'openwrt2020')
        for (const other of labels.filter((l) => l.text !== 'Fail'))
          expect(reddish(other.fill), `${other.text} is ${other.fill}`).toBe(false);

      await h.screenshot(panel, `settings-findings-${theme}-${scheme}`);
    });
  }
});
