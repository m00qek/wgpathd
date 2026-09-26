# How to Build the Package

The package is built in the official OpenWrt SDK image, inside Docker. The result is one architecture-independent `.apk`.

---

## Build

```bash
make package
```

The first run builds a `wgpathd-sdk` image from `ghcr.io/openwrt/sdk` and updates the feed metadata, which takes a while. The package lands in `bin/`:

```
bin/wgpathd-0.1.0-r1.apk
```

For the full SDK build output, add `VERBOSE=1`.

The build mounts `openwrt/wgpathd/Makefile`, `src/` and `files/` read-only into the SDK. Only the metadata of the runtime dependencies is used; none of them are compiled.

## Check the package

```bash
make package-check
```

This builds the package, then installs it into a fresh `ghcr.io/openwrt/rootfs` container and checks that:

- its dependencies resolve and it installs, and the service start during install does nothing;
- every file is in place with the right mode, nothing is installed on the `PATH`, there is no uci-defaults script, and `/etc/config/wgpathd` is a conffile shipped with `enabled '0'`;
- the modules load from the default ucode search path;
- `daemon.uc` and `check.uc --config` with the shipped configuration, and `status.uc` with no daemon, fail with a one-line reason rather than a ucode stack trace;
- the full `check.uc` passes a valid hub configuration without ubus;
- the init script enables, fw4 includes the firewall file, and the package scripts reload the firewall on install, upgrade and removal;
- the package removes cleanly, taking the firewall file with it.

The last line is `package-check: all passed`, or the number of failed checks. The container runs no procd or ubusd, so starting the service, the ubus object and the firewall reload itself are out of its reach.

## Build for another release

```bash
make package OPENWRT_VERSION=25.12.5
make package-check OPENWRT_VERSION=25.12.5
```

`OPENWRT_VERSION` and `OPENWRT_ARCH` select the SDK and rootfs image tags. The package is the same for every architecture.

## Change what is packaged

- Version and release: `PKG_VERSION` and `PKG_RELEASE` in `openwrt/wgpathd/Makefile`.
- Dependencies: `DEPENDS` in the same file. The root `Makefile` reads this line to install the same dependencies into the test image, so tests always run against them.
- Installed files: the `Package/wgpathd/install` section. When you add a file, add a matching check to `devenv/scripts/package-check.sh` and a row to [Files and dependencies](../../reference/files.md).
