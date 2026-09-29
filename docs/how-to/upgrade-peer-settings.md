# How to Upgrade from a Release That Kept Peer Settings in the Network Configuration

Releases up to 4 kept each steered peer's relay endpoint and tunnel address as the options `wgpathd_relay` and `wgpathd_tunnel` of its section in `/etc/config/network`. Later releases read them from a [`peer` section](../reference/uci-config.md#peer-sections) of `/etc/config/wgpathd` instead, keyed by the peer's public key, and ignore the old options.

The package moves them for you. This guide shows how to check that it did, and how to do it by hand if it could not.

## Prerequisites

- A spoke that runs a release up to 4 with its peers steered.
- The new package, built and copied to the router as in [How to install wgpathd](install.md).
- The firewall rules of [How to open the firewall for wgpathd](open-firewall.md), added on every node.

!!! warning "Add the firewall rules before you upgrade"
    Releases up to 5 loaded wgpathd's firewall accepts themselves, and the upgrade removes them from the running firewall. Without the rules added first, a zone that rejects input rejects the probes, relayed packets and peer list as soon as the upgrade finishes, and the peers lose their direct paths, and possibly the relay.

---

## 1. Upgrade the package

```bash
apk add --allow-untrusted /tmp/wgpathd-0.1.0-r*.apk
```

During the upgrade, the package's post-upgrade script, through OpenWrt's `default_postinst`, runs `/etc/uci-defaults/50-wgpathd-peers`, which runs `/usr/libexec/wgpathd/migrate.uc`. For each WireGuard peer section in `/etc/config/network` with either option, it:

1. adds a `peer` section with that section's `public_key` to `/etc/config/wgpathd`, or completes the one already there, as `relay` and `tunnel`;
2. commits `/etc/config/wgpathd`;
3. deletes `wgpathd_relay` and `wgpathd_tunnel` from the network section, and commits `/etc/config/network`.

Only then does the script restart the running daemon, so it starts with the moved settings. A value `/etc/config/wgpathd` already holds is kept, and no copy of `/etc/config/network` is written.

## 2. Check the result

```bash
logread -e 'migrate:'
```

```
Sun Sep 27 16:02:11 2026 daemon.notice wgpathd[2210]: migrate: moved the settings of 1 peer(s) from /etc/config/network to /etc/config/wgpathd
```

The settings are now in `/etc/config/wgpathd`, and gone from `/etc/config/network`:

```bash
uci show wgpathd | grep '@peer'
grep wgpathd_ /etc/config/network
```

The first command prints a `public_key`, `relay` and `tunnel` for each steered peer; the second prints nothing. Then run the check:

```bash
service wgpathd check
```

Each peer you steered before has an `ok  peer` line, no line says `left over from an earlier version`, and every `firewall:` line is `ok`.

## If it could not move them

The log says why:

- `migrate: failed, /etc/config/network left as it was: MIGRATE_FAILED (<detail>)`: a file could not be read or written; the details are in [Error codes](../reference/error-codes.md#migration). `/etc/config/network` is unchanged, and `/etc/uci-defaults/50-wgpathd-peers` is kept, so it runs again at the next boot. After fixing the cause, run it at once with `service wgpathd migrate`, then `service wgpathd reload`.
- `migrate: network section <section> has no valid public_key, its options stay`: that section cannot be keyed. Fix its `public_key`, then run `service wgpathd migrate` and `service wgpathd reload`.
- `migrate: network section <section>: kept relay '<value>' of /etc/config/wgpathd, dropped wgpathd_relay '<value>'`: `/etc/config/wgpathd` already had a different value, which wins. If the dropped one was right, set it with `uci set` and reload.

Until the settings are moved, the peers are `not configured`: wgpathd leaves their endpoints alone, and the check and the log at startup name every network section still holding the old options.

## To move them by hand

For each peer section that still has the options, `spoke_b` here, copy them into a new `peer` section, commit `/etc/config/wgpathd`, and only then remove them from `/etc/config/network`:

```bash
uci add wgpathd peer
uci set wgpathd.@peer[-1].public_key="$(uci get network.spoke_b.public_key)"
uci set wgpathd.@peer[-1].relay="$(uci get network.spoke_b.wgpathd_relay)"
uci set wgpathd.@peer[-1].tunnel="$(uci get network.spoke_b.wgpathd_tunnel)"
uci commit wgpathd

uci delete network.spoke_b.wgpathd_relay
uci delete network.spoke_b.wgpathd_tunnel
uci commit network
```

Skip `uci add` for a peer that already has a `peer` section: two sections with one key leave the peer unsteered, `configured more than once`. Then check and apply:

```bash
service wgpathd check
service wgpathd reload
```

`service wgpathd migrate` does the same for every peer at once.
