# WireGuard Substrate

wgpathd reads the WireGuard setup from `/etc/config/network` and never writes it. It reads it at startup and again on every reload (`service wgpathd reload`). Its own settings, including those of each steered peer, are in `/etc/config/wgpathd`; see [UCI configuration](uci-config.md).

---

## What wgpathd reads from network

| Read | By | For |
| :--- | :--- | :--- |
| The `interface` sections named by `mesh_iface`, `hub_iface` or `read_iface` | Both roles | They must exist; see [Validation order](uci-config.md#validation-order). |
| Every section of type `wireguard_<mesh_iface>`, for example `wireguard_wg_mesh`: its name and `public_key` | Spoke | The mesh peers. Each is matched by `public_key` to a [`peer` section](uci-config.md#peer-sections) of `/etc/config/wgpathd`, and named by its section name in logs, the status and the check. |
| The `addresses` of every interface with `proto 'wireguard'` | Hub, `service wgpathd check` only | The warning when `serve_addr` is no address of a WireGuard interface. |
| The options `wgpathd_relay` and `wgpathd_tunnel` of any section | Both roles | Only to warn that they are left over; see [below](#options-left-over-from-earlier-releases). |

wgpathd does not read `endpoint`, `allowed_ips`, the keys or any other option of a peer. A steered peer should have no `endpoint` option; wgpathd sets the endpoint at runtime.

The rpcd plugin's [`peers` method](ubus-config-check.md#peers) reads the same peer sections, and returns only their names, public keys and descriptions.

## Example

A spoke's peer section for spoke-b in `/etc/config/network`, and the `peer` section that makes wgpathd steer it, in `/etc/config/wgpathd`:

```
config wireguard_wg_mesh 'spoke_b'
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	list allowed_ips '10.12.0.0/16'
	list allowed_ips '10.20.0.12/32'
	option route_allowed_ips '1'
```

```
config peer
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	option relay      '10.10.0.12:51820'
	option tunnel     '10.20.0.12'
```

## Options left over from earlier releases

Releases up to 4 kept a peer's settings as the options `wgpathd_relay` and `wgpathd_tunnel` of its section in `/etc/config/network`. They are no longer read. The package moves them into `/etc/config/wgpathd` when it is installed or upgraded; see [How to upgrade from a release that kept peer settings in the network configuration](../how-to/upgrade-peer-settings.md).

While a section still has either option, the daemon logs `network section <section>: ignoring <options>, left over from an earlier version; run service wgpathd migrate` once at startup, and `service wgpathd check` warns about it.

## Substrate requirements

wgpathd does not check these, but relaying and probing depend on them.

- **The relay host routes via the hub tunnel.** The spoke's `wg_hub` peer for the hub must include the transit range (for example `10.10.0.0/24`) in `allowed_ips`, with a route installed. No `wg_mesh` peer may include any transit address.
- **The hub forwards between its `wg_hub` peers** within the transit range.
- **Relayed packets are accepted.** They arrive on the spoke's `wg_hub` interface, addressed to the `wg_mesh` listen port. The package's firewall include accepts this for port `51820`; see [Firewall rules](firewall.md).
- **The tunnel address answers ping** through `wg_mesh`.
- **The hub is a `wg_mesh` peer of every spoke,** with a fixed IPv6 endpoint and a persistent keepalive, so the hub sees each spoke's current IPv6 endpoint. See [About discovery](../explanation/discovery.md).

[How to prepare the WireGuard substrate](../how-to/prepare-substrate.md) shows a complete working layout.
