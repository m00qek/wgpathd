# How to Configure the Hub

On the hub, wgpathd reads the `wg_mesh` peer table and publishes the spokes' IPv6 endpoints on its `wg_hub` address. It steers nothing.

## Prerequisites

- wgpathd is installed and stopped: [How to install wgpathd](install.md).
- The hub has `wg_mesh` and `wg_hub` as in [How to prepare the WireGuard substrate](prepare-substrate.md), and spokes are handshaking on `wg_mesh`.

---

## 1. Write the configuration

Replace the contents of `/etc/config/wgpathd` with:

```
config wgpathd 'main'
	option role       'hub'
	option read_iface 'wg_mesh'
	option serve_addr '10.10.0.1'
	option serve_port '7780'
```

- `read_iface` is the interface whose peer endpoints are published: the mesh, where the spokes' IPv6 endpoints appear.
- `serve_addr` is the hub's own address on `wg_hub`. Spokes reach it through the tunnel that stays up when the mesh is down.
- Keep `serve_port` at `7780` unless you also add your own firewall rule for another port; the shipped rule only accepts `7780`.

Every option is described in [UCI configuration](../reference/uci-config.md#hub-options).

## 2. Start the service

```bash
service wgpathd restart
logread -e wgpathd | tail -n 5
```

The log should end with:

```
daemon.info wgpathd[2481]: started as hub
```

If you see `invalid configuration:` or `startup failed:` instead, look up the code in [Log messages](../reference/log-messages.md#startup-and-exit). A common one is `PUBLISHER_LISTEN_FAILED (...: bind(): Address not available)`: `serve_addr` is not an address of this host, or `wg_hub` is not up.

## 3. Check what is published

On the hub:

```bash
ubus call wgpathd status
```

`peers` should list each spoke's `wg_mesh` public key with a `direct` IPv6 endpoint. From a spoke, fetch the same data over `wg_hub`:

```bash
uclient-fetch -qO- http://10.10.0.1:7780/peers
```

A spoke missing from the list has no IPv6 endpoint in the hub's `wg_mesh` table. Check that spoke's `wg_mesh` peer for the hub has an IPv6 endpoint and `persistent_keepalive`.

## Optional: keep the discovery port off WAN

The shipped rule accepts TCP `7780` on every interface, ahead of zone rules. The listener only binds `serve_addr`, so nothing answers on the public address. If your policy requires the port to be closed on WAN anyway, add a chain that runs before fw4's `input` chain. Files in `/etc/nftables.d/` are included inside fw4's table. For example, in `/etc/nftables.d/10-wgpathd-wan.nft`, with your WAN device in place of `eth1`:

```
chain wgpathd_wan_guard {
	type filter hook input priority filter - 1; policy accept;
	iifname "eth1" tcp dport 7780 drop
}
```

Then run `service firewall reload`. See [Firewall rules](../reference/firewall.md#scope).
