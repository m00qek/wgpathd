// devenv/gh-pages/404.html: the redirect from unversioned links to latest/.
// Runs the page's own script against a fake window.location.
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

const page = fs.readFileSync(`${__dirname}/../../devenv/gh-pages/404.html`, "utf8");
const script = /<script>([\s\S]*?)<\/script>/.exec(page)[1];

function redirectOf(href) {
  const url = new URL(href, "https://example.github.io");
  let target = null;
  const location = {
    pathname: url.pathname,
    search: url.search,
    hash: url.hash,
    replace: (to) => { target = to; },
  };
  vm.runInNewContext(script, { window: { location } });
  return target;
}

const cases = [
  ["an unversioned deep link keeps its query and anchor",
    "/wgpathd/how-to/install/?q=spoke#upgrade", "/wgpathd/latest/how-to/install/?q=spoke#upgrade"],
  ["an unversioned page", "/wgpathd/reference/uci-config/", "/wgpathd/latest/reference/uci-config/"],
  ["a file without a trailing slash", "/wgpathd/sitemap.xml", "/wgpathd/latest/sitemap.xml"],
  ["the site root", "/wgpathd/", "/wgpathd/latest/"],
  ["the site root without a slash", "/wgpathd", "/wgpathd/latest/"],
  ["a missing page under latest/ stays", "/wgpathd/latest/nope/", null],
  ["a missing page under a version stays", "/wgpathd/0.9/nope/", null],
  ["a missing page under a two-digit minor stays", "/wgpathd/0.10/nope/", null],
  ["a missing page under dev/ stays", "/wgpathd/dev/nope/", null],
  ["a version folder itself stays", "/wgpathd/0.9", null],
  ["the host root stays", "/", null],
  ["a folder that only starts like a version moves", "/wgpathd/0.9x/", "/wgpathd/latest/0.9x/"],
];

let failures = 0;
for (const [name, from, to] of cases) {
  try {
    assert.strictEqual(redirectOf(from), to);
    console.log(`ok   ${name}`);
  } catch (e) {
    console.log(`FAIL ${name}: ${from} -> ${redirectOf(from)}, expected ${to}`);
    failures++;
  }
}
process.exit(failures > 0 ? 1 : 0);
