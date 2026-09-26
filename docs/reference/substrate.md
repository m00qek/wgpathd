# Substrate Annotations

On a spoke, wgpathd reads its peers from `/etc/config/network`: every section of type `wireguard_<mesh_iface>`, for example `wireguard_wg_mesh`. It reads them once, at startup. wgpathd never writes this file.

netifd ignores the `wgpathd_*` options, so they can sit next to the peer's normal options.

---

## Options read per peer

| Option | Required | Format | Description |
| :--- | :--- | :--- | :--- |
| `public_key` | Yes | WireGuard public key: 43 base64 characters followed by `=` | Identifies the peer in the kernel, in discovery and in the status output. |
| `wgpathd_relay` | Yes | Endpoint: `v4:port` or `[v6]:port`, port 1–65535 | The endpoint used on the relay path: the peer's address on the hub tunnel and the peer's `wg_mesh` listen port. Must route out of an interface other than `mesh_iface`. |
| `wgpathd_tunnel` | Yes | IPv4 or IPv6 address, no port | The peer's address inside `wg_mesh`. Target of the tunnel probe. Must be inside the peer's `allowed_ips`. |

wgpathd does not read `endpoint`, `allowed_ips` or any other option of the peer. A steered peer should have no `endpoint` option; wgpathd sets the endpoint at runtime.

Endpoints and addresses are stored in canonical form (lowercase, compressed IPv6), so `[2001:DB8::0001]:51820` and `[2001:db8::1]:51820` are the same.

## Example

```
config wireguard_wg_mesh 'spoke_b'
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	list allowed_ips '10.12.0.0/16'
	list allowed_ips '10.20.0.12/32'
	option route_allowed_ips '1'
	option wgpathd_relay '10.10.0.12:51820'
	option wgpathd_tunnel '10.20.0.12'
```

## Managed and unmanaged peers

A peer is **managed** when all three options are present and valid, and its relay address routes out of an interface other than `mesh_iface`. wgpathd steers only managed peers.

Any other peer is **unmanaged**: wgpathd never touches its endpoint. Unmanaged peers are logged at startup and listed in the `unmanaged` array of [`ubus call wgpathd status`](ubus-status.md). The checks run in this order; the first failure is the reason reported.

| Reason | Cause | Permanent |
| :--- | :--- | :--- |
| `invalid public_key` | `public_key` missing or not a valid key | Yes |
| `missing wgpathd_relay` | No `wgpathd_relay` option | Yes |
| `invalid wgpathd_relay` | `wgpathd_relay` is not a valid `v4:port` or `[v6]:port` | Yes |
| `missing wgpathd_tunnel` | No `wgpathd_tunnel` option | Yes |
| `invalid wgpathd_tunnel` | `wgpathd_tunnel` is not a valid IP address | Yes |
| `relay routes into <mesh_iface>` | The route to the relay host leaves via `mesh_iface` | Yes |
| `relay route lookup failed: <error>` | The route lookup for the relay host failed, for example because `wg_hub` is not up yet | No: rechecked every cycle |

"Permanent" means until the next restart. A peer waiting on a failed route lookup is rechecked at the start of every cycle. When its route resolves out of another interface it becomes managed, starting in RELAY, and wgpathd logs `relay route found, now managed`. If the route resolves into `mesh_iface`, it becomes permanently unmanaged.

The spoke's own `wg_mesh` peer for the hub normally has no annotations, so it is always listed as unmanaged with `missing wgpathd_relay`. That is expected: the hub peer keeps its static endpoint.

## Substrate requirements

wgpathd does not check these, but relaying and probing depend on them.

- **The relay host routes via the hub tunnel.** The spoke's `wg_hub` peer for the hub must include the transit range (for example `10.10.0.0/24`) in `allowed_ips`, with a route installed. No `wg_mesh` peer may include any transit address.
- **The hub forwards between its `wg_hub` peers** within the transit range.
- **Relayed packets are accepted.** They arrive on the spoke's `wg_hub` interface, addressed to the `wg_mesh` listen port. The package's firewall include accepts this for port `51820`; see [Firewall rules](firewall.md).
- **The tunnel address answers ping** through `wg_mesh`.
- **The hub is a `wg_mesh` peer of every spoke,** with a fixed IPv6 endpoint and a persistent keepalive, so the hub sees each spoke's current IPv6 endpoint. See [About discovery](../explanation/discovery.md).

[How to prepare the WireGuard substrate](../how-to/prepare-substrate.md) shows a complete working layout.
