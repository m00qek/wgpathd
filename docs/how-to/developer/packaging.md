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

- its dependencies resolve and it installs;
- every file is in place with the right mode, and `/etc/config/wgpathd` is a conffile;
- the uci-defaults script ran and was removed;
- the modules load from the default ucode search path;
- `wgpathd` with the default configuration, and `wgpathd status` with no daemon, fail with a one-line reason rather than a ucode stack trace;
- the init script enables, and fw4 includes the firewall file.

The last line is `package-check: all passed`, or the number of failed checks. The container runs no procd or ubusd, so starting the service and the ubus object are out of its reach.

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
