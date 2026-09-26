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

This compiles every ucode file, including the scripts in `files/usr/libexec/wgpathd/`, and runs `sh -n` on the init script and the devenv scripts. CI runs `make lint` and `make test` on every push.

## Test against another OpenWrt release

```bash
make test OPENWRT_VERSION=25.12.5
```

`OPENWRT_VERSION` and `OPENWRT_ARCH` select the rootfs image. Each combination gets its own development image.

## Where tests go

- `test/unit/` mirrors `src/`: one test file per module, with every I/O dependency replaced by a fake. The decision core is tested here, including property tests over random observation sequences.
- `test/integration/` drives the daemon shell and the publisher through `daemon.create(...)` with fake `deps`, and runs the publisher on a real loopback socket.

For the reasoning behind the split, see [Architecture](../../explanation/architecture.md).
