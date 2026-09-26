# How to Install wgpathd

wgpathd is one architecture-independent `.apk` package for OpenWrt 25.12 and later. Install the same package on the hub and on every spoke; the role is chosen in configuration afterwards.

## Prerequisites

- The WireGuard substrate is in place: [How to prepare the WireGuard substrate](prepare-substrate.md).
- The router can reach its package feeds, so `apk` can pull in the dependencies.
- A checkout of the wgpathd repository and Docker on your workstation, to build the package.

---

## 1. Build the package

In the repository:

```bash
make package
```

This builds `bin/wgpathd-0.1.0-r1.apk` in the OpenWrt SDK, inside Docker. See [How to build the package](developer/packaging.md) for other versions and checks.

## 2. Copy it to the router

```bash
scp bin/wgpathd-0.1.0-r1.apk root@192.0.2.1:/tmp/
```

If the router has no SFTP server, add `-O` to use the legacy SCP protocol.

## 3. Install it

On the router:

```bash
apk update
apk add --allow-untrusted /tmp/wgpathd-0.1.0-r1.apk
```

`--allow-untrusted` is needed because a locally built package is not signed with a key the router trusts. The dependencies come from the regular feeds; the full list is in [Files and dependencies](../reference/files.md#dependencies).

## 4. Check the result

The package ships its configuration with `enabled '0'`, so nothing runs until you configure a role:

```bash
service wgpathd status
```

```
active with no instances
disabled (option enabled in /etc/config/wgpathd)
```

Installing also reloads the firewall, which loads the package's rules:

```bash
nft list ruleset | grep 'wgpathd:'
```

You should see four rules whose comments start with `wgpathd:`. They assume UDP `51820` for `wg_mesh` and TCP `7780` for discovery; see [Firewall rules](../reference/firewall.md) if yours differ.

## Next

- On the hub: [How to configure the hub](configure-hub.md).
- On each spoke: [How to configure a spoke](configure-spoke.md).

## To upgrade

Build and copy the new package, then run `apk add --allow-untrusted` on it as above. Your `/etc/config/wgpathd` is kept, and the firewall is reloaded with the new rules. A running daemon keeps the old code until you restart it:

```bash
service wgpathd restart
```

Every peer starts again in RELAY and earns direct within a few cycles.
