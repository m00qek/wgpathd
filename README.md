# wgpathd

Hub-and-spoke path selection for a WireGuard mesh: **relay inter-site traffic
through the hub by default, and upgrade a peer pair to a direct point-to-point
path whenever at least one peer is reachable on public IPv6.** ucode, OpenWrt-native.

- **Design & rationale:** the explanation pages in [`docs/explanation/`](docs/explanation/index.md)
  (direct and relay, state machine, discovery, trust model, architecture).
- **Reference implementation** for structure/conventions: `../luci-sso`.

## Documentation
User and developer docs live in [`docs/`](docs/index.md) (MkDocs Material, Diátaxis):
tutorials, how-to guides, reference and explanation. Preview with `make docs-serve`
(http://localhost:8000) or build with `make docs`; both run in Docker.

## Layout
- `src/wgpathd/` — ucode modules (pure `decide` core + `deps`-injected shell).
- `files/` — OpenWrt package payload (config, procd service, libexec scripts, the uci-defaults migration of peer settings, rpcd plugin).
- `luci/` — `luci-app-wgpathd`, the LuCI pages (Status → Mesh paths with a Status → Overview
  section, Network → Mesh paths, a form over /etc/config/wgpathd),
  laid out like an openwrt/luci `applications/` directory; packaged alongside the daemon,
  pinned to its exact version.
- `test/` — `unit` / `integration` (utest) + `e2e` (docker) + `browser` (Playwright, LuCI pages).
- `devenv/` — docker-compose e2e harness (faithful OpenWrt, no LuCI).
- `openwrt/wgpathd/` — OpenWrt buildroot package Makefile.

## Development
Everything runs in a pinned OpenWrt rootfs container (Docker only; nothing to install).
```
make test                      # unit + integration
make unit FILTER='name' VERBOSE=1
make unit MODULES=test/unit/wgpathd/decide_test.uc
make watch                     # re-run on change
make lint                      # ucode compile check + sh -n + LuCI JSON and scripts, no HTML sinks, template up to date
make shell                     # throwaway shell in the image
make package                   # build bin/wgpathd-*.apk and bin/luci-app-wgpathd-*.apk in the OpenWrt SDK
make package-check             # install both in a fresh rootfs and verify them
make browser                   # Playwright tests of the LuCI pages against a fake wgpathd and the real rpcd plugin
make pot                       # regenerate the LuCI translation template with openwrt/luci's scanner
```
`OPENWRT_VERSION` / `OPENWRT_ARCH` select the rootfs (default `25.12.5` / `x86_64`).

Status: **implemented and packaged**, with unit, integration and browser tests and a docker failover harness of fifteen scenarios. Release 6 passes all fifteen scenarios; earlier releases run on a small production mesh.
