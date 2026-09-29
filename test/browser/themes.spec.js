const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// The path strip has no colours of its own: segments and nodes are drawn in the
// text colour (currentColor). In every theme and scheme they must stand out from
// the background behind them.
const THEMES = [
  { theme: 'bootstrap', scheme: 'light' },
  { theme: 'bootstrap', scheme: 'dark' },
  { theme: 'bootstrap-dark', scheme: 'light' },
  { theme: 'openwrt2020', scheme: 'light' },
  { theme: 'material', scheme: 'light' },
];

// WCAG's minimum contrast for graphical objects.
const MIN_CONTRAST = 3;

// For each strip in the view, the contrast of its segments' and hub node's colours
// with the nearest opaque background behind it. One synchronous pass over the view,
// which a refresh cannot replace halfway.
function stripContrasts(view) {
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
  const luminance = ([ r, g, b ]) => {
    const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  };
  const contrast = (a, b) => {
    const [ l1, l2 ] = [ luminance(a), luminance(b) ].sort((x, y) => y - x);
    return (l1 + 0.05) / (l2 + 0.05);
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

  return Array.from(view.querySelectorAll('.wgpathd-path')).map((path) => {
    const bg = background(path.parentElement);
    const spans = Array.from(path.children);
    return {
      peer: spans[spans.length - 1].textContent,
      segments: spans.filter((s) => s.textContent === '').map((s) => contrast(over(getComputedStyle(s).borderTopColor, bg), bg)),
      hub: spans.filter((s) => s.textContent === 'hub').map((s) => contrast(over(getComputedStyle(s).backgroundColor, bg), bg)),
    };
  });
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

      const strips = await page.locator('#view').evaluate(stripContrasts);
      expect(strips.map((c) => c.peer)).toEqual([ 'beach', 'home', 'lab' ]);
      for (const c of strips)
        for (const value of c.segments.concat(c.hub))
          expect(value, `${c.peer} in ${theme}`).toBeGreaterThanOrEqual(MIN_CONTRAST);

      await h.peerRow(page, 'beach').getByRole('button').click();
      await h.screenshot(page, `theme-${theme}-${scheme}`);
    });
  }
});
