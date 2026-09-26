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

## 4. Stop the service until it is configured

OpenWrt enables and starts a package's service as soon as it is installed. At this point wgpathd runs with the shipped template: a spoke in observe mode on `wg_mesh` and `wg_hub`.

- If those interfaces exist, it starts as a spoke and sets every annotated `wg_mesh` peer to its relay endpoint. That is safe, but on the hub it is the wrong role.
- If they do not, it exits with `invalid configuration: INTERFACE_MISSING (wg_mesh)` and procd restarts it every 5 seconds.

Stop it until you have configured the role:

```bash
service wgpathd stop
```

The service stays enabled, so it starts at the next boot.

## 5. Load the firewall rules

Installing does not reload the firewall. Load the shipped include now:

```bash
service firewall reload
nft list ruleset | grep 'wgpathd:'
```

You should see four rules whose comments start with `wgpathd:`. Before you continue, read [Firewall rules](../reference/firewall.md): the rules assume `wg_mesh`, UDP `51820` and TCP `7780`, and the discovery port is accepted on every interface.

## Next

- On the hub: [How to configure the hub](configure-hub.md).
- On each spoke: [How to configure a spoke](configure-spoke.md).

## To upgrade

Build and copy the new package, then run `apk add --allow-untrusted` on it as above. Your `/etc/config/wgpathd` is kept. Then run `service wgpathd restart` so the new code is running. Every peer starts again in RELAY and earns direct within a few cycles.
