# How to Run the Tests

All tests run in a pinned OpenWrt rootfs container with `utest`. You need Docker and `make`; nothing else is installed on the host.

---

## Run everything

```bash
make test
```

This runs the unit suite (`test/unit`) and the integration suite (`test/integration`). The first run builds the `wgpathd-openwrt` image, which takes a few minutes.

To run one suite:

```bash
make unit
make integration
```

## Narrow it down

Run tests whose name matches a regular expression:

```bash
make unit FILTER='trial'
```

Run specific files or directories:

```bash
make unit MODULES=test/unit/wgpathd/decide_test.uc
make test MODULES='test/unit/wgpathd/config_test.uc test/integration/daemon_test.uc'
```

See one line per test, with the failing assertion:

```bash
make test VERBOSE=1
```

The variables combine.

## Re-run on every change

```bash
make watch
```

This runs all tests, then again each time a file under `src/`, `test/` or `files/` changes. `FILTER` and `MODULES` apply. Stop it with Ctrl+C.

## Lint

```bash
make lint
```

This compiles every ucode file, including the scripts in `files/usr/libexec/wgpathd/`, runs `sh -n` on the init script and the devenv scripts, parses the LuCI JSON and scripts, fails on LuCI code that could turn data into markup (`innerHTML` and the like, or `%s` in a `.format()` template), and checks pinned documentation links (see [Link check](../../reference/docs-publishing.md#link-check)). CI runs `make lint` and `make test` on every push.

## Check for memory leaks

```bash
make leak
```

This runs the prober, a discovery fetch against the publisher and a command, each about a thousand times, on the real uloop in the development container, and fails if any keeps more than 64 bytes of memory per use. The daemon repeats each of them thousands of times a day, so a few kilobytes per use is a router out of memory within weeks. It takes a few seconds, and needs raw sockets, which Docker grants by default; the prober only reaches loopback, as the container has no other network.

The usual cause is uloop's: it keeps a timer that has fired until the timer is cancelled, and a callback that captures its own timer, process or connection is never freed. Cancel a one-shot timer when it fires, and drop such references once the work is done.

## Test the docs tooling

```bash
make docs-test
```

This runs `test/docs/` in the docs tools image, without network: the version, guard, publish and link-check scripts in `devenv/scripts/docs-*.sh`, with `docs-publish.sh` deploying three releases through mike to a throwaway local repository, and the redirect in `devenv/gh-pages/404.html` under Node. The first run builds the `wgpathd-docs` image. CI runs it on pull requests and pushes to `main` that touch the docs or their tooling.

## Run the browser tests

```bash
make browser
make browser FILTER='hub'
```

This builds both packages, then runs the Playwright tests in `test/browser/` against the LuCI pages: Status → Mesh paths, the Status → Overview section, Network → Mesh paths, hostile text in every free-text field, and the path strip in five themes. The first run builds the `wgpathd-luci` and `wgpathd-browser` images.

LuCI runs in an OpenWrt rootfs container with the built packages, started by hand without procd. A fake `wgpathd` ubus object (`devenv/services/luci/fake-wgpathd.uc`) answers `ubus call wgpathd status` with a fixture from `test/fixtures/luci/`, which each test chooses; the fixture `none` withdraws the object, as when the daemon is not running. The fixtures freeze `now`, so every age and wait on the page is fixed. An integration test in `test/integration/daemon_test.uc` checks that each fixture has the fields and value types of the daemon's own reply, so a change to the reply fails `make test` until the fixtures follow it.

`wgpathd.config` is not faked: rpcd serves it with the package's own plugin, so the settings page, its ACL and the plugin are tested together. The fake's `wgpathd.fixture config` writes `/etc/config/network` and `/etc/config/wgpathd` from a directory of `test/fixtures/luci/config/`, and `read` returns them as saved, which the tests compare after Save & Apply. The container also has the login `meshadmin` (password `meshadmin`), granted only rpcd's `unauthenticated` group, `luci-base` and `luci-app-wgpathd`: the tests use the settings page as that login, and check that it cannot read `network`.

The LuCI container runs with `--network none` and no capabilities, and uhttpd listens on `127.0.0.1`. The Playwright container joins its network namespace (`--network container:`), so the browser reaches LuCI over that loopback and neither container has any other network. Both are removed when the run ends, also on failure or Ctrl+C.

Screenshots of the main states are in `bin/browser/screenshots/`; on failure, Playwright's screenshots and error context and the LuCI container's log are in `bin/browser/`.

## Update the translation template

```bash
make pot
```

Run it after adding or changing a string in `_()` or `N_()` in `luci/`, or a menu or ACL title, and commit `luci/po/templates/wgpathd.pot` with the change: `make lint` fails while the template is out of date. The template is written by openwrt/luci's own scanner, so it matches what upstream would generate. The scanner reads JavaScript with xgettext, which can lose its way on a regular expression literal with a quote or an unescaped `/` in a character class; it then warns, and `make pot` and `make lint` fail rather than drop strings. Write such a literal without them, for example `\/` inside the brackets.

## Test against another OpenWrt release

```bash
make test OPENWRT_VERSION=25.12.5
```

`OPENWRT_VERSION` and `OPENWRT_ARCH` select the rootfs image. Each combination gets its own development image.

## Run the end-to-end failover suite

```bash
make e2e
make e2e SCENARIO=kill-direct
make e2e SCENARIO='baseline roam'
```

This builds the package, then boots three OpenWrt containers (`hub`, `spoke-a`, `spoke-b`) with procd as PID 1, installs the package in each, and runs the failover scenarios against them: steady DIRECT, relay fallback with traffic surviving, a direct path that drops full-size packets, the anchor-only estate (also under steady traffic), a dead direct path under relay traffic, crash and hang recovery, roaming, a mesh interface netifd creates again, hub loss, the mixed state and observe mode. The scenarios are listed in `test/e2e/README.md`. A full run takes several minutes.

The containers get only `NET_ADMIN` and `NET_RAW`, share one internal docker network, and use the host kernel's WireGuard module, which the kernel loads on first use. The network is not IPv6-enabled in docker; netifd in each container configures the IPv6 addresses. An IPv6-enabled docker network would make docker switch on the host's `net.ipv6.conf.all.forwarding`, even for an internal network.

The runner guards the host:

- It warns about containers of other projects that are running, and refuses to start beside them with `E2E_STRICT=1`. It always refuses while the lab runs, since both use the same addresses.
- It records `ip monitor` and the kernel log for the whole run, and tears the stack down at once if the Wi-Fi interface (`wlan0`, or `E2E_WATCH_IFACE`) goes down or the kernel log mentions it.
- It records `net.ipv6.conf.all.forwarding` and the interface's `accept_ra` before and after, and reports any change.
- It always tears the stack down, including on failure or Ctrl+C.

Results, timings, per-failure node logs and the guard's logs are in `bin/e2e/`.

## Where tests go

- `test/unit/` mirrors `src/`: one test file per module, with every I/O dependency replaced by a fake. The decision core is tested here, including property tests over random observation sequences.
- `test/integration/` drives the daemon shell and the publisher through `daemon.create(...)` with fake `deps`, and runs the publisher on a real loopback socket.
- `test/e2e/` holds one shell script per failover scenario, run on the host against the containers by `make e2e`.
- `test/browser/` holds the Playwright tests of the LuCI pages, `test/fixtures/luci/` the status replies they run against, and `test/fixtures/luci/config/` the configurations of the settings page tests.

For the reasoning behind the split, see [Architecture](../../explanation/architecture.md).
