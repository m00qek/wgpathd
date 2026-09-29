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

This compiles every ucode file, including the scripts in `files/usr/libexec/wgpathd/`, runs `sh -n` on the init script and the devenv scripts, and checks pinned documentation links (see [Link to the documentation](publish-docs.md#link-to-the-documentation)). CI runs `make lint` and `make test` on every push.

## Test the docs tooling

```bash
make docs-test
```

This runs `test/docs/` in the docs tools image, without network: the version, guard, publish and link-check scripts in `devenv/scripts/docs-*.sh`, with `docs-publish.sh` deploying three releases through mike to a throwaway local repository, and the redirect in `devenv/gh-pages/404.html` under Node. The first run builds the `wgpathd-docs` image. CI runs it on pull requests and pushes to `main` that touch the docs or their tooling.

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

This builds the package, then boots three OpenWrt containers (`hub`, `spoke-a`, `spoke-b`) with procd as PID 1, installs the package in each, and runs the failover scenarios against them: steady DIRECT, relay fallback with traffic surviving, a direct path that drops full-size packets, the anchor-only estate (also under steady traffic), a dead direct path under relay traffic, crash and hang recovery, roaming, hub loss, the mixed state and observe mode. The scenarios are listed in `test/e2e/README.md`. A full run takes several minutes.

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

For the reasoning behind the split, see [Architecture](../../explanation/architecture.md).
