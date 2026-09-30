# How to Publish a Release to the Package Feed

Routers install wgpathd and luci-app-wgpathd from the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed. The feed builds them from the release tarball GitHub serves for a tag, with a Makefile generated from `openwrt/wgpathd/Makefile`. The examples publish `0.2.0`.

## Prerequisites

- The release is tagged and pushed: `v0.2.0`, with `PKG_VERSION:=0.2.0` in `openwrt/wgpathd/Makefile`.
- A checkout of packages.ucode.dev next to this one.

The feed fetches the tarball of `v<PKG_VERSION>`, so a release that only raises `PKG_RELEASE` cannot reach the feed: publish a new version instead.

---

## 1. Generate the feed Makefile

```bash
make feed-makefile VERSION=0.2.0 OUT=../packages.ucode.dev/wgpathd/Makefile
```

This downloads the `v0.2.0` tarball, hashes it, and writes the Makefile. If it refuses, it names the line of `openwrt/wgpathd/Makefile` it does not know how to transform.

## 2. Commit it to the feed

In packages.ucode.dev, commit `wgpathd/Makefile` and push it to `main`. Do not edit the file there: the feed's `wgpathd` workflow regenerates it from the tag and fails if the two differ.

The workflow then builds both packages with the OpenWrt 25.12 SDK, signs them into `25.12/noarch/`, and adds them to every architecture's index.

## 3. Check the feed

On a router with the feed configured:

```bash
apk update
apk info -a wgpathd | head -3
```

The version shown is `0.2.0-r<PKG_RELEASE>`.
