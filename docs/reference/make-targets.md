# Make Targets

All targets run in Docker. Nothing is installed on the host.

---

## Root `Makefile`

| Target | Description |
| :--- | :--- |
| `test` | Run the unit and integration suites. |
| `unit` | Run the unit suite only. |
| `integration` | Run the integration suite only. |
| `watch` | Run all tests, then re-run whenever a file under `src/`, `test/` or `files/` changes. |
| `lint` | Compile-check every ucode file and `sh -n` every shell script. |
| `shell` | Open a throwaway shell in the development image. |
| `image` | Rebuild the development image, pulling the base image again. |
| `package` | Build `bin/wgpathd-<version>-r<release>.apk` in the OpenWrt SDK. |
| `package-check` | Run `package`, then install the result offline in an OpenWrt rootfs container that already carries its dependencies (no network, `NET_ADMIN` in its own empty namespace) and check files, modes, package scripts, clean failure paths, that fw4 loads and unloads the firewall rules, and removal. |
| `e2e` | Run `package`, then the end-to-end failover scenarios against a hub and two spokes in OpenWrt containers (procd as PID 1, kernel WireGuard, fw4), compose project `wgpathd-e2e`, image `wgpathd-e2e:<arch>-<version>`. Refuses to start while another project's containers run, guards the host's Wi-Fi interface for the whole run, and always tears down. Results in `bin/e2e/`. |
| `docs` | Build the documentation site (same as `make -C docs build`). |
| `docs-serve` | Serve the documentation with live reload (same as `make -C docs serve`). |

`test`, `unit`, `integration`, `watch`, `lint` and `shell` run in the `wgpathd-openwrt:<arch>-<version>` image, which is built on first use from `devenv/services/openwrt/Dockerfile` and rebuilt when that file or `openwrt/wgpathd/Makefile` changes. The container has no network.

### Variables

| Variable | Default | Applies to | Description |
| :--- | :--- | :--- | :--- |
| `OPENWRT_VERSION` | `25.12.5` | all | OpenWrt release of the rootfs and SDK images. |
| `OPENWRT_ARCH` | `x86_64` | all | Target architecture; selects the `ghcr.io/openwrt/rootfs` and `ghcr.io/openwrt/sdk` image tags. The package itself is architecture-independent. |
| `FILTER` | — | `test`, `unit`, `integration`, `watch` | Run only tests whose name matches this regular expression. |
| `VERBOSE` | — | tests, `package` | Tests: detailed reporter with one line per test. `package`: verbose SDK build (`V=s`). |
| `MODULES` | — | `test`, `unit`, `integration`, `watch` | Run only these test files or directories. |
| `CI` | — | all | When set, runs containers without a TTY. |
| `SCENARIO` | all | `e2e` | Run only these scenarios (space-separated names from `test/e2e/`). |
| `E2E_WATCH_IFACE` | `wlan0` | `e2e` | Host interface the e2e runner guards; the run stops if it goes down. |

Examples:

```bash
make unit FILTER='trial' VERBOSE=1
make unit MODULES=test/unit/wgpathd/decide_test.uc
```

## `docs/Makefile`

| Target | Description |
| :--- | :--- |
| `build` | Build the site into `bin/site/` with `mkdocs build --strict`. |
| `serve` | Serve the site with live reload on `http://localhost:8000`. `dev` is an alias. |
| `clean` | Remove `bin/site/`. |
| `help` | List the targets. This is the default. |

Both run the pinned `squidfunk/mkdocs-material:9.5.17` image as the invoking user.
