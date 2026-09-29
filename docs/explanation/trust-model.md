# Trust Model

wgpathd runs on routers that you manage over the same tunnels it steers. A bug or a hostile party must never be able to lock you out, read your traffic, or redirect it. This page explains how the design keeps those promises, and what it assumes.

---

## The hub is not trusted with anything that matters

The hub is usually a rented VPS, the most exposed machine in the setup. wgpathd is built so that a compromised hub can deny service, and nothing more.

- **It cannot read site traffic.** On `wg_mesh` the hub's AllowedIPs for each spoke cover only that spoke's tunnel address, never its site networks. When the hub relays, it forwards `wg_mesh` packets that are still encrypted end to end between the two spokes.
- **It cannot redirect traffic.** The hub publishes only candidate endpoints. A spoke uses a candidate only after its own tunnel probe gets an answer from the peer, and that answer has to come through a WireGuard session keyed with the peer's static key. An endpoint that leads anywhere else fails the trial, and the peer returns to the relay with a growing backoff.
- **It cannot move the floor.** The relay endpoint of each peer comes from the spoke's own configuration (the `relay` of its `peer` section), never from discovery. A spoke with no discovery at all, even at a cold boot with the hub down, can always set every peer to relay.
- **It cannot confuse the parser.** A discovery payload that breaks any limit is rejected as a whole. See [discovery](discovery.md).
- **It cannot aim the probes inside the router or the tunnels.** A published address that is loopback, link-local, multicast or otherwise no place for a direct path is ignored, and so is one that belongs to the spoke itself, is the peer's relay or tunnel address, or routes into `wg_mesh` or `wg_hub`.

What a hostile hub can do is stop relaying, stop publishing, or publish wrong addresses. Direct paths that already work keep working without it. Pairs that need the relay lose connectivity until the hub is back, which is true of any hub-and-spoke network.

## Endpoints only

wgpathd's one mutating action is `wg set <mesh_iface> peer <key> endpoint <addr>`. The core that makes decisions can only produce a fixed set of effects: set an endpoint, send a tunnel probe, ask for a discovery refresh, log, and report a metric. No effect exists for creating interfaces, changing AllowedIPs, touching routes, or writing configuration. So the scope limit holds by construction, not by care. See [architecture](architecture.md).

The practical meaning: the worst a wgpathd bug can do is point a mesh peer at a wrong endpoint. That peer degrades to the relay, or at worst stops working over `wg_mesh`. The `wg_hub` tunnel, which you use to reach the router, is never touched.

## Why it never creates interfaces or distributes identities

Tools in this space often manage the whole overlay: they generate keys, hand out peers and addresses, and create interfaces. wgpathd deliberately does none of that.

- Creating or rewriting interfaces would mean writing `/etc/config/network`. A bug there could take down `wg_hub`, the tunnel you need to fix the bug. The daemon never writes it. The one program of the package that does is the migration from releases up to 4, which, after an upgrade, deletes the two options those releases kept on peer sections, `wgpathd_relay` and `wgpathd_tunnel`, and nothing else.
- Distributing peers or keys through the hub would make the hub a source of identity. Then a compromised hub could add a peer or widen AllowedIPs, and read traffic. Keeping keys and AllowedIPs in static configuration, rendered by you, keeps the hub out of that path entirely.

So wgpathd is a tenant, not a landlord. You own the substrate. wgpathd checks at startup that the interfaces it was told about exist and refuses to run if they do not; `service wgpathd check` runs the same checks on demand. Each mesh peer it would steer must have valid settings in wgpathd's own configuration, found by the peer's public key; a peer that does not is left alone and reported as unmanaged.

The same line runs through the LuCI pages. `/etc/config/network` holds the private key of every WireGuard interface on the router, so the `luci-app-wgpathd` ACL grants no access to it at all: a peer's settings live in `/etc/config/wgpathd`, and the pages name the peers through a read-only rpcd method that returns each peer's section name, public key and description, and nothing else. See [Files and dependencies](../reference/files.md#acl).

## Relay loop guard

A relay endpoint must route into `wg_hub`. If it routed into `wg_mesh` instead, relayed packets would loop into the tunnel they are supposed to carry. At startup, and again each cycle for peers still waiting, wgpathd looks up the route to each peer's relay address. A peer whose relay route leaves via `mesh_iface` is left unmanaged, with the reason `relay routes into <mesh_iface>`, and is guarded again on every reload.

## Authenticated roams

Roams count as evidence because they are authenticated. The kernel only moves a peer's endpoint after a packet from that address decrypted correctly with the peer's key. An attacker who can spoof source addresses cannot cause a roam without the key.

## Firewall

The package ships its own firewall rules so that the probes and the relay work as soon as it is installed. Three of the four rules accept only packets that came out of a WireGuard interface, which only a key holder can produce. The fourth accepts ICMPv6 echo requests from anywhere, so that other spokes can probe this node's public address. Read the [firewall rules reference](../reference/firewall.md) before you deploy.

## Why wgpathd runs as root

Like most OpenWrt services, wgpathd runs as root rather than as a jailed, unprivileged user. It has to hold the network-admin capability to run `wg set`, and that capability alone already lets a process rewrite routes, firewall rules and interfaces, so a jail would protect little that matters. What limits the damage instead is the narrow input surface: a spoke rejects any discovery payload that is not fully valid, and the hub's discovery server answers one fixed request with data that is already public to the mesh.

Where that server can be reached is partly up to you. wgpathd binds it to the one address in `serve_addr` and refuses a wildcard, a host name or a multicast address there, so it never listens on every interface at once. It does not make sure that the address belongs to a WireGuard interface: the configuration says which address, not which interface, and `service wgpathd check` only warns when no WireGuard interface in `/etc/config/network` has it. The shipped firewall rule accepts the port only from WireGuard interfaces, but your zone rules may accept it from elsewhere, for example from LAN when `serve_addr` is a LAN address.

## Further reading

The [design record](../design.md) covers the scope boundary (Decision 4), the relay endpoint resolution (R1) and the failure-mode catalog rows for a lying hub.
