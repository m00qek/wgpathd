# How to Configure a Spoke

On a spoke, wgpathd steers the endpoint of each annotated `wg_mesh` peer. This guide starts it in observe mode, where every managed peer is held on its relay endpoint while wgpathd reports what it would do. Turning on steering is a separate step.

## Prerequisites

- wgpathd is installed and stopped: [How to install wgpathd](install.md).
- The spoke's `wg_mesh` and `wg_hub` are set up and annotated as in [How to prepare the WireGuard substrate](prepare-substrate.md).
- wgpathd is installed on the other spokes too. Each spoke must answer the others' tunnel probes and accept relayed packets, which the package's firewall rules provide.
- The hub is configured: [How to configure the hub](configure-hub.md).

---

## 1. Write the configuration

Replace the contents of `/etc/config/wgpathd` with:

```
config wgpathd 'main'
	option role       'spoke'
	option mesh_iface 'wg_mesh'
	option hub_iface  'wg_hub'
	option discovery  'http://10.10.0.1:7780/peers'
	option mode       'observe'
```

`discovery` is the hub's `serve_addr` and `serve_port` with the path `/peers`. This file can be identical on every spoke: everything peer-specific lives in `/etc/config/network`.

Every option is described in [UCI configuration](../reference/uci-config.md#spoke-options).

## 2. Start the service

```bash
service wgpathd restart
logread -e wgpathd | tail -n 5
```

A healthy start looks like this:

```
daemon.info wgpathd[3107]: peer section hub unmanaged: missing wgpathd_relay
daemon.info wgpathd[3107]: started as spoke
```

The hub peer is always unmanaged, since it has no annotations; that line is expected. Any other `unmanaged` line names a peer wgpathd will not touch, and why. See [Substrate annotations](../reference/substrate.md#managed-and-unmanaged-peers) for the reasons.

If the log shows `invalid configuration:` or `startup failed:`, look up the code in [Log messages](../reference/log-messages.md#startup-and-exit).

## 3. Check the relay path

Within a few seconds every managed peer is on its relay endpoint:

```bash
ubus call wgpathd status
```

Each entry under `peers` should show `"state": "RELAY"` and `"endpoint"` equal to its `wgpathd_relay`, and `discovery.fresh` should be `true`. Then prove the relay carries traffic, using the other spoke's tunnel address:

```bash
ping -c3 10.20.0.12
```

If this fails, the relay floor does not work yet, and there is no point in turning on steering. Check that the hub forwards the transit range and that the other spoke has reloaded its firewall after installing wgpathd.

## 4. Watch for readiness

Leave the spoke in observe mode for a while and watch `ready` and `up_streak` in the status of each peer. `ready: true` means the peer has enough direct evidence that steer mode would start a trial.

A peer that never becomes ready has no direct evidence. For an anchor, that is normal until the other side steers: its evidence is the other side's direct traffic. For a roamer, check that `discovery.fresh` is `true` and that the peer's IPv6 address answers `ping -6`.

When the relay works and peers become ready, continue with [How to move a spoke from observe to steer](enable-steering.md).
