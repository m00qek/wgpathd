# How to Configure a Spoke

On a spoke, wgpathd steers the endpoint of each `wg_mesh` peer you give a relay endpoint and a tunnel address. This guide starts it in observe mode, where every managed peer is held on its relay endpoint while wgpathd reports what it would do. Turning on steering is a separate step.

## Prerequisites

- wgpathd is installed: [How to install wgpathd](install.md).
- The spoke's `wg_mesh` and `wg_hub` are set up as in [How to prepare the WireGuard substrate](prepare-substrate.md).
- wgpathd is installed on the other spokes too. Each spoke must answer the others' tunnel probes and accept relayed packets, which the package's firewall rules provide.
- The hub is configured: [How to configure the hub](configure-hub.md).

---

## 1. Write the configuration

Replace the contents of `/etc/config/wgpathd` with:

```
config wgpathd 'main'
	option enabled    '1'
	option role       'spoke'
	option mesh_iface 'wg_mesh'
	option hub_iface  'wg_hub'
	option discovery  'http://10.10.0.1:7780/peers'
	option mode       'observe'

config peer
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	option relay      '10.10.0.12:51820'
	option tunnel     '10.20.0.12'
```

`discovery` is the hub's `serve_addr` and `serve_port` with the path `/peers`.

Add one `peer` section for each other spoke:

- `public_key` is that spoke's key, as in its `wg_mesh` peer section in `/etc/config/network`. Print it with `uci get network.spoke_b.public_key`.
- `relay` is that spoke's transit address plus its `wg_mesh` listen port.
- `tunnel` is its tunnel address, which must be in its `allowed_ips`.

Give the hub peer no `peer` section: wgpathd leaves it alone.

Every option is described in [UCI configuration](../reference/uci-config.md#spoke-options), and the `peer` section in [Peer sections](../reference/uci-config.md#peer-sections).

## 2. Check the configuration

```bash
service wgpathd check
```

```
ok    config: spoke, mode observe, 1 steered peer, 1 not steered
ok    wg_mesh: up, 2 peers
ok    wg_hub: up, 1 peer
ok    peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12
skip  peer hub: not steered (not configured)
```

There should be one `ok  peer` line per other spoke, with its relay `via wg_hub`. The hub peer is always `skip`, since it has no `peer` section. Fix every `FAIL` and `warn` line before you go on; [Service commands](../reference/service-commands.md#findings) explains each one, and [Managed and unmanaged peers](../reference/uci-config.md#managed-and-unmanaged-peers) the peer reasons.

## 3. Start the service and check the relay path

```bash
service wgpathd start
service wgpathd status
```

Within a few seconds every managed peer is on its relay endpoint:

```
running
role: spoke (mode observe)
discovery: fresh (last success 2s ago)
peers:
  spoke_b  SpokeBme  RELAY  10.10.0.12:51820  no change yet  0 switches
unmanaged:
  hub  HubMeshP  not configured
```

Each peer should be in `RELAY` with its `relay` as the endpoint, and discovery should be `fresh`. The log has a matching `started role=spoke mode=observe managed=1 unmanaged=1` line. If the first line is not `running`, look at `logread -e wgpathd | tail -n 5` and find the code in [Log messages](../reference/log-messages.md#startup-and-exit).

Then prove the relay carries traffic, using the other spoke's tunnel address:

```bash
ping -c3 10.20.0.12
```

If this fails, the relay floor does not work yet, and there is no point in turning on steering. Check that the hub forwards the transit range and that wgpathd is installed on the other spoke, whose firewall rules accept the relayed packets.

## 4. Watch for readiness

Leave the spoke in observe mode for a while and watch `ready` and `up_streak` for each peer in `ubus call wgpathd status`. `ready: true` means the peer has enough direct evidence that steer mode would start a trial.

A peer that never becomes ready has no direct evidence. For an anchor, that is normal until the other side steers: its evidence is the other side's direct traffic. For a roamer, check that `discovery.fresh` is `true` and that the peer's IPv6 address answers `ping -6`.

When the relay works and peers become ready, continue with [How to move a spoke from observe to steer](enable-steering.md).
