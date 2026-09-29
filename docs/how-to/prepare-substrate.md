# How to Prepare the WireGuard Substrate

This guide sets up the WireGuard interfaces that wgpathd steers. wgpathd never creates or edits them; it checks they exist and refuses to start otherwise. Do this once per node, before you install wgpathd.

The examples use one hub and two spokes. spoke-a accepts inbound IPv6 (the anchor); spoke-b does not (a roamer). Replace every key and address with your own.

| | hub | spoke-a | spoke-b |
| :--- | :--- | :--- | :--- |
| Public address | `203.0.113.10`, `2001:db8:ff::1` | `2001:db8:a::1` | changes |
| `wg_hub` address (transit) | `10.10.0.1/24` | `10.10.0.11/32` | `10.10.0.12/32` |
| `wg_mesh` address (tunnel) | `10.20.0.1/32` | `10.20.0.11/32` | `10.20.0.12/32` |
| Site network | — | `10.11.0.0/16` | `10.12.0.0/16` |

If you already run hub-and-spoke on one interface, that interface can be your `wg_hub`. Keep its name; wgpathd only needs to be told which it is.

---

## Before you start

- Generate **two keypairs per node**, one for `wg_hub` and one for `wg_mesh`. Do not reuse a key across interfaces.
- Give the mesh interface a fixed listen port on every node, `51820` in the examples: the other spokes' relay endpoints name it, and the firewall accepts relayed packets on it. The examples call the interfaces `wg_hub` and `wg_mesh`, but any names work: you tell wgpathd which is which.
- Keep the `wg_mesh` MTU at least 60 bytes below the `wg_hub` MTU, so a relayed packet fits inside the hub tunnel. The examples use `1360` inside the default `1420`.

## 1. Configure the hub

Add both interfaces to `/etc/config/network` on the hub.

```
config interface 'wg_hub'
	option proto 'wireguard'
	option private_key '<hub wg_hub private key>'
	option listen_port '51830'
	list addresses '10.10.0.1/24'

config wireguard_wg_hub 'spoke_a_transit'
	option public_key 'SpokeAhubPublicKeyExample000000000000000000='
	list allowed_ips '10.10.0.11/32'

config wireguard_wg_hub 'spoke_b_transit'
	option public_key 'SpokeBhubPublicKeyExample000000000000000000='
	list allowed_ips '10.10.0.12/32'

config interface 'wg_mesh'
	option proto 'wireguard'
	option private_key '<hub wg_mesh private key>'
	option listen_port '51820'
	option mtu '1360'
	list addresses '10.20.0.1/32'

config wireguard_wg_mesh 'spoke_a'
	option public_key 'SpokeAmeshPublicKeyExample00000000000000000='
	list allowed_ips '10.20.0.11/32'
	option route_allowed_ips '1'

config wireguard_wg_mesh 'spoke_b'
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	list allowed_ips '10.20.0.12/32'
	option route_allowed_ips '1'
```

Section names must be unique in the whole file, even across section types: UCI refuses a `wireguard_wg_mesh 'spoke_a'` next to a `wireguard_wg_hub 'spoke_a'`. The examples add `_transit` to the `wg_hub` peers.

On `wg_mesh`, give each spoke only its tunnel `/32`, never its site network. The hub relays encrypted `wg_mesh` packets and must not be able to decrypt site traffic.

The hub's `wg_mesh` peers have no endpoint. The hub learns each spoke's IPv6 endpoint from the spoke's keepalives, and that is what it publishes for discovery.

## 2. Let the hub forward the transit range

The relay works by the hub forwarding packets from one spoke's transit address to another's, in and out of `wg_hub`. In `/etc/config/firewall` on the hub, allow forwarding within the zone that holds `wg_hub`. If that zone is called `vpn`:

```
config rule
	option name 'wg_hub-transit'
	option src 'vpn'
	option dest 'vpn'
	option dest_ip '10.10.0.0/24'
	option target 'ACCEPT'
```

Setting `option forward 'ACCEPT'` on the zone also works. Do not narrow this to UDP: the same forward usually carries management traffic between sites.

Also accept the WireGuard ports from WAN: UDP `51830` for `wg_hub` and UDP `51820` for `wg_mesh`.

## 3. Configure each spoke

On spoke-a, add to `/etc/config/network`:

```
config interface 'wg_hub'
	option proto 'wireguard'
	option private_key '<spoke-a wg_hub private key>'
	list addresses '10.10.0.11/32'

config wireguard_wg_hub 'hub_transit'
	option public_key 'HubHubPublicKeyExample000000000000000000000='
	option endpoint_host '203.0.113.10'
	option endpoint_port '51830'
	list allowed_ips '10.10.0.0/24'
	option route_allowed_ips '1'
	option persistent_keepalive '25'

config interface 'wg_mesh'
	option proto 'wireguard'
	option private_key '<spoke-a wg_mesh private key>'
	option listen_port '51820'
	option mtu '1360'
	list addresses '10.20.0.11/32'

config wireguard_wg_mesh 'hub'
	option public_key 'HubMeshPublicKeyExample00000000000000000000='
	option endpoint_host '2001:db8:ff::1'
	option endpoint_port '51820'
	list allowed_ips '10.20.0.1/32'
	option route_allowed_ips '1'
	option persistent_keepalive '25'

config wireguard_wg_mesh 'spoke_b'
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	list allowed_ips '10.12.0.0/16'
	list allowed_ips '10.20.0.12/32'
	option route_allowed_ips '1'
```

The points that matter:

- **The hub's `wg_hub` peer holds the whole transit range** (`10.10.0.0/24`) with a route. That is what makes a relay endpoint such as `10.10.0.12:51820` travel through `wg_hub`.
- **The hub is also a `wg_mesh` peer, with a fixed IPv6 endpoint and a keepalive.** The keepalive keeps the hub's view of this spoke's IPv6 endpoint current. wgpathd never steers this peer: you give it no settings in `/etc/config/wgpathd`.
- **Every other spoke is a `wg_mesh` peer with no endpoint.** wgpathd sets the endpoint. What it needs to steer the peer, its relay endpoint (that spoke's transit address plus its `wg_mesh` listen port, here `10.10.0.12:51820`) and its tunnel address (`10.20.0.12`, which must be in its `allowed_ips`), goes into `/etc/config/wgpathd` when you [configure the spoke](configure-spoke.md), not here.
- **No `wg_mesh` peer may include any transit address** in `allowed_ips`. Otherwise the relay endpoint would route into `wg_mesh` and wgpathd would refuse to manage that peer.

spoke-b mirrors this with its own keys and addresses. Its `spoke_a` peer has `allowed_ips` `10.11.0.0/16` and `10.20.0.11/32`; its relay endpoint is `10.10.0.11:51820` and its tunnel address `10.20.0.11`.

## 4. Open inbound IPv6 on reachable sites

On each spoke that should accept direct connections (spoke-a here), accept UDP `51820` from WAN over IPv6:

```
config rule
	option name 'Allow-wg_mesh'
	option src 'wan'
	option family 'ipv6'
	option proto 'udp'
	option dest_port '51820'
	option target 'ACCEPT'
```

A roaming site behind a stateful firewall (spoke-b) needs no inbound rule. Its outgoing probes open the way.

Put `wg_hub` and `wg_mesh` in a firewall zone, `vpn` in the examples, as your site policy requires. A zone that holds only them keeps the rules wgpathd needs, added in the next guide, from opening anything to other networks.

## 5. Apply and check

Apply on each node:

```bash
service network reload
service firewall reload
```

Then check:

- On the hub, `wg show wg_mesh endpoints` lists each spoke with an IPv6 endpoint, such as `[2001:db8:a::1]:51820`. This is exactly what discovery will publish.
- On each spoke, `ip route get 10.10.0.12` (the other spoke's transit address) answers `dev wg_hub`.
- On each spoke, `wg show wg_mesh` lists the hub peer with a recent handshake, and the other spokes with no endpoint.

The spokes cannot yet reach each other over `wg_mesh`: their mesh peers have no endpoint until wgpathd sets one. Continue with [How to open the firewall for wgpathd](open-firewall.md), then [How to install wgpathd](install.md).
