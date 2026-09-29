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
| `lint` | Compile-check every ucode file, `sh -n` every shell script, and check that pinned documentation links (`<site_url><X.Y>/`) use the package's minor in shipped files and their section's minor in `CHANGELOG.md` (`devenv/scripts/docs-links.sh`; nothing to check while `site_url` is unset). |
| `shell` | Open a throwaway shell in the development image. |
| `image` | Rebuild the development image, pulling the base image again. |
| `package` | Build `bin/wgpathd-<version>-r<release>.apk` in the OpenWrt SDK. |
| `package-check` | Run `package`, then install the result offline in an OpenWrt rootfs container that already carries its dependencies (no network, `NET_ADMIN` in its own empty namespace) and check files, modes, package scripts, clean failure paths, that fw4 loads and unloads the firewall rules, and removal. |
| `e2e` | Run `package`, then the end-to-end failover scenarios against a hub and two spokes in OpenWrt containers (procd as PID 1, kernel WireGuard, fw4), compose project `wgpathd-e2e`, image `wgpathd-e2e:<arch>-<version>`. Refuses to start while another project's containers run, guards the host's Wi-Fi interface for the whole run, and always tears down. Results in `bin/e2e/`. |
| `lab-up` | Run `package`, then start the e2e topology as compose project `wgpathd-lab` (containers `wgpathd-lab-hub`, `wgpathd-lab-spoke-a`, `wgpathd-lab-spoke-b`) with the WireGuard substrate in place and wgpathd installed but disabled (shipped `/etc/config/wgpathd`, `enabled '0'`) on every node. Returns once the hub has handshakes with both spokes on `wg_hub` and `wg_mesh`. The same host guards as `e2e` apply, and the watchdog keeps running in the background until `lab-down`. Guard logs in `bin/lab/`. |
| `lab-down` | Stop the lab's watchdog, tear the lab down and print the host report (sysctls, Wi-Fi interface, kernel log). Safe to run when the lab is not up. |
| `lab-shell` | Open a login shell on the lab node named by `NODE`. |
| `lab-fault` | Inject or clear a fault in the running lab, named by `NAME`: `kill-direct` drops the `wg_mesh` datagrams between the spokes (the e2e `kill-direct` fault: the hub leg, the relay and ICMPv6 stay up); `relay-delay` delays everything the hub sends by `MS` milliseconds (netem on the hub's `eth0`), which slows only the relay path, since the direct path never crosses the hub; `restore` clears every fault. |
| `docs` | Build the documentation site (same as `make -C docs build`). |
| `docs-mike` | Strict build with the versioned config (same as `make -C docs build-mike`). |
| `docs-test` | Test the docs publishing tooling (same as `make -C docs test`). |
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
| `NODE` | — | `lab-shell` | `hub`, `spoke-a` or `spoke-b`. |
| `NAME` | — | `lab-fault` | `kill-direct`, `relay-delay` or `restore`. |
| `MS` | — | `lab-fault` | Milliseconds of delay for `NAME=relay-delay`. |
| `E2E_STRICT` | — | `e2e`, `lab-up` | Set to `1` to refuse to start while containers of other projects run. By default they are listed as a warning and the run goes ahead. The lab and the suite always refuse to run at the same time. |
| `E2E_WATCH_IFACE` | `wlan0` | `e2e`, `lab-up` | Host interface the e2e runner and the lab guard; the stack is torn down if it goes down. |

Examples:

```bash
make unit FILTER='trial' VERBOSE=1
make unit MODULES=test/unit/wgpathd/decide_test.uc
```

## `docs/Makefile`

| Target | Description |
| :--- | :--- |
| `build` | Build the site into `bin/site/` with `mkdocs build --strict`. |
| `build-mike` | Build the site into `bin/site/` with `mkdocs build --strict --config-file mkdocs.mike.yml`: the versioned config the release publish uses (mike plugin, version selector, outdated-version banner). |
| `test` | Run `test/docs/`: the docs version, guard, publish and link-check scripts, with a full mike publish to a throwaway local repository, and the `gh-pages` 404 redirect. No network. |
| `serve` | Serve the site with live reload on `http://localhost:8000`, or on the port set by `DOCS_PORT`. `dev` is an alias. |
| `clean` | Remove `bin/site/`. |
| `help` | List the targets. This is the default. |

`build` and `serve` run the pinned `squidfunk/mkdocs-material:9.5.17` image as the invoking user. `build-mike` and `test` run `wgpathd-docs:9.5.17`, the same image plus the pinned mike from `devenv/services/docs/requirements.txt`, git and Node, built on first use from `devenv/services/docs/Dockerfile` and rebuilt when it or the requirements change. `DOCS_PORT` (default `8000`) sets the host port for `serve`, for example when another project's preview already uses 8000: `make -C docs serve DOCS_PORT=8001`. It also works from the root: `make docs-serve DOCS_PORT=8001`.
