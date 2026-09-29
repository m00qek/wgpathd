# How to Build the Package

The packages are built in the official OpenWrt SDK image, inside Docker. The result is two architecture-independent `.apk` files with the same version: `wgpathd`, the daemon, and `luci-app-wgpathd`, its LuCI pages.

---

## Build

```bash
make package
```

The first run builds a `wgpathd-sdk` image from `ghcr.io/openwrt/sdk` and updates the feed metadata (base, packages and luci), which takes a while. The packages land in `bin/`:

```
bin/wgpathd-0.1.0-r6.apk
bin/luci-app-wgpathd-0.1.0-r6.apk
```

For the full SDK build output, add `VERBOSE=1`.

The build mounts `openwrt/wgpathd/Makefile`, `src/`, `files/` and `luci/` read-only into the SDK. Only the metadata of the runtime dependencies is used; none of them are compiled.

## Check the package

```bash
make package-check
```

This builds the packages and a check image (the pinned rootfs plus both packages' dependencies, including `luci-base`, and `quickjs`), then installs the daemon offline in a container with no network and `NET_ADMIN` in its own empty network namespace, and checks that:

- it installs without fetching anything, and the service start during install does nothing;
- every file is in place with the right mode, nothing is installed on the `PATH`, there is no uci-defaults script, and `/etc/config/wgpathd` is a conffile shipped with `enabled '0'`;
- the modules load from the default ucode search path;
- `daemon.uc` and `check.uc --config` with the shipped configuration, and `status.uc` with no daemon, fail with a one-line reason rather than a ucode stack trace;
- the full `check.uc` passes a valid hub configuration without ubus, and prints the firewall rule that hub needs;
- a real rpcd serves `wgpathd.config` from the plugin, and its check reads `/etc/config/firewall` and reports a missing rule with the rule to add;
- the init script enables, and the package ships no firewall rule and loads none;
- the package scripts reload rpcd on install, upgrade and removal, may reload the firewall only on install and upgrade, restart a running daemon on upgrade, and parse;
- `luci-app-wgpathd` depends on exactly the daemon's version, and apk refuses it next to any other wgpathd release;
- the app installs on top of the daemon, ships only its menu, ACL and two views with mode 0644, the menu and ACL parse as JSON, the views parse as JavaScript (with quickjs, as the function body LuCI compiles them into), and its scripts parse;
- installing and removing the app clear LuCI's menu and module caches, and removing it keeps the daemon;
- the daemon package removes cleanly;
- an upgrade from a release that shipped the fw4 include, simulated in apk's database, removes the file and unloads its four rules.

The last line is `package-check: all passed`, or the number of failed checks. The container runs no procd or ubusd, so starting the service and the ubus object are out of its reach.

## Build for another release

```bash
make package OPENWRT_VERSION=25.12.5
make package-check OPENWRT_VERSION=25.12.5
```

`OPENWRT_VERSION` and `OPENWRT_ARCH` select the SDK and rootfs image tags. The package is the same for every architecture.

## Change what is packaged

- Version and release: `PKG_VERSION` and `PKG_RELEASE` in `openwrt/wgpathd/Makefile`.
- Dependencies: `DEPENDS` in each package's `define Package/<name>` block of the same file. The root `Makefile` reads the daemon's to install the same dependencies into the test image, so tests always run against them, and both to build the package-check image.
- Installed files: the `Package/wgpathd/install` and `Package/luci-app-wgpathd/install` sections. The app installs everything under `luci/htdocs` into `/www` and everything under `luci/root` into `/`. When you add a file, add a matching check to `devenv/scripts/package-check.sh` and a row to [Files and dependencies](../../reference/files.md).
