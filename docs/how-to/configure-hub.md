# How to Configure the Hub

On the hub, wgpathd reads the `wg_mesh` peer table and publishes the spokes' IPv6 endpoints on its `wg_hub` address. It steers nothing.

## Prerequisites

- wgpathd is installed: [How to install wgpathd](install.md).
- The hub has `wg_mesh` and `wg_hub` as in [How to prepare the WireGuard substrate](prepare-substrate.md), and spokes are handshaking on `wg_mesh`.

---

## 1. Write the configuration

Replace the contents of `/etc/config/wgpathd` with:

```
config wgpathd 'main'
	option enabled    '1'
	option role       'hub'
	option read_iface 'wg_mesh'
	option serve_addr '10.10.0.1'
	option serve_port '7780'
```

- `read_iface` is the interface whose peer endpoints are published: the mesh, where the spokes' IPv6 endpoints appear.
- `serve_addr` is the hub's own address on `wg_hub`. Spokes reach it through the tunnel that stays up when the mesh is down.
- Keep `serve_port` at `7780` unless you also add your own firewall rule for another port; the shipped rule only accepts `7780`, and only through WireGuard.

Every option is described in [UCI configuration](../reference/uci-config.md#hub-options).

## 2. Check the configuration

```bash
service wgpathd check
```

```
ok    config: hub, reads wg_mesh, serves 10.10.0.1:7780
ok    wg_mesh: up, 2 peers
```

Fix every `FAIL` line before you go on. Each line is explained in [Service commands](../reference/service-commands.md#findings).

## 3. Start the service

```bash
service wgpathd start
service wgpathd status
```

```
running
role: hub
published peers:
  SpokeAme  [2001:db8:a::1]:51820   handshake 12s ago
  SpokeBme  [2001:db8:b::20]:51820  handshake 7s ago
```

The log has a `started role=hub` line. If the first line is `not running`, or `wgpathd: cannot read status` follows it, look at `logread -e wgpathd | tail -n 5` and find the code in [Log messages](../reference/log-messages.md#startup-and-exit). A common one is `startup failed: PUBLISHER_LISTEN_FAILED (...: bind(): Address not available)`: `serve_addr` is not an address of this host, or `wg_hub` is not up.

## 4. Check what is published

Each spoke should be listed under `published peers` with a direct IPv6 endpoint. From a spoke, fetch the same data over `wg_hub`:

```bash
uclient-fetch -qO- http://10.10.0.1:7780/peers
```

A spoke missing from the list has no IPv6 endpoint in the hub's `wg_mesh` table. Check that spoke's `wg_mesh` peer for the hub has an IPv6 endpoint and `persistent_keepalive`.
