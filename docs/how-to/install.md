# How to Install wgpathd

wgpathd is one architecture-independent `.apk` package for OpenWrt 25.12 and later. Install the same package on the hub and on every spoke; the role is chosen in configuration afterwards.

## Prerequisites

- The WireGuard substrate is in place: [How to prepare the WireGuard substrate](prepare-substrate.md).
- The firewall accepts what wgpathd needs: [How to open the firewall for wgpathd](open-firewall.md). The package adds no firewall rules.
- The router can reach its package feeds, so `apk` can pull in the dependencies.
- A checkout of the wgpathd repository and Docker on your workstation, to build the package.

---

## 1. Build the package

In the repository:

```bash
make package
```

This builds `bin/wgpathd-0.1.0-r8.apk` in the OpenWrt SDK, inside Docker. See [How to build the package](developer/packaging.md) for other versions and checks.

## 2. Copy it to the router

```bash
scp bin/wgpathd-0.1.0-r8.apk root@192.0.2.1:/tmp/
```

If the router has no SFTP server, add `-O` to use the legacy SCP protocol.

## 3. Install it

On the router:

```bash
apk update
apk add --allow-untrusted /tmp/wgpathd-0.1.0-r8.apk
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

Installing reloads rpcd, which then serves the configuration check over ubus, daemon or not:

```bash
ubus call wgpathd.config check
```

Until you configure a role, the answer has `"ok": false` and a finding `config: option role must be 'spoke' or 'hub' (is unset)`. See [ubus config check](../reference/ubus-config-check.md).

## Next

- On the hub: [How to configure the hub](configure-hub.md).
- On each spoke: [How to configure a spoke](configure-spoke.md).

## To upgrade

!!! warning "From release 5 or earlier: add the firewall rules first"
    Releases up to 5 loaded wgpathd's firewall accepts themselves; this one does not, and the upgrade removes them from the running firewall. On every node, add the rules of [How to open the firewall for wgpathd](open-firewall.md) **before** you upgrade it. Otherwise a zone that rejects input rejects wgpathd's probes, relayed packets and peer list from the moment the upgrade finishes.

Build and copy the new package, then run `apk add --allow-untrusted` on it as above. Your `/etc/config/wgpathd` is kept, and a running daemon is restarted on the new code. Every peer starts again in RELAY and earns direct within a few cycles. After an upgrade from release 5 or earlier, run `service wgpathd check` and make sure no `firewall:` line is a warning.

Releases up to 4 kept each peer's relay endpoint and tunnel address in `/etc/config/network`. An upgrade from one of them moves those settings into `/etc/config/wgpathd` before the daemon restarts; [How to upgrade from a release that kept peer settings in the network configuration](upgrade-peer-settings.md) shows how to check that it did.
