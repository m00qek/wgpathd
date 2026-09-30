# Why wgpathd?

If your sites already talk through a WireGuard hub, wgpathd lets pairs of sites talk directly whenever they can, and fall back to the hub whenever they cannot, without changing the tunnels you already run. This page is about when that is worth having, and when another tool is the better choice.

---

## What going direct buys

In plain hub-and-spoke, every byte between two sites crosses the hub. Taking the hub out of that path gives three things, in order of how much you can count on them:

- **Sites keep talking when the hub is down.** A direct session is peer to peer. Once two sites are direct, a hub outage, reboot or upgrade does not touch the traffic between them. This is the benefit that does not depend on anyone's ISP.
- **The hub carries less.** Site-to-site traffic stops using the hub's bandwidth and CPU. On a small VPS with a traffic allowance, every pair that goes direct is traffic the hub no longer pays for.
- **Latency, sometimes.** Direct is shorter only when the ISPs route it that way. On one real pair of sites the direct path measured about 13 ms against 25 ms through the hub; after one site's ISP renumbered it, the same pair measured about 23 ms against 24 ms. Treat lower latency as a bonus, not the reason.

## The alternatives

### Staying on the hub

The simplest setup, and the right one if the hub is close, reliable and not short of bandwidth. wgpathd keeps it as its floor: every peer can always go back to the hub, using a relay endpoint from local configuration that nothing on the network can change.

### A script that pings and runs `wg set`

This is the usual answer on OpenWrt. A ping-and-switch script works on a good day. What it tends to miss is what makes the switch safe:

- **A reply is not proof of the path.** A ping through the tunnel can be answered over the hub, because the other side's traffic through the hub pulls the endpoint back there, so the reply proves the peer is alive, not that the direct path works. wgpathd commits only when the answer comes back over the direct path itself, with a full-size packet. See [evidence first, then proof](state-machine.md#evidence-first-then-proof).
- **Addresses move.** Home ISPs renumber IPv6 prefixes. A script with the other site's address written into it breaks quietly when that happens. wgpathd learns current addresses from the hub, see [discovery](discovery.md).
- **Paths flap, and some addresses never work.** Without hysteresis a marginal path switches back and forth; without a limit a stale address is retried forever. wgpathd drops fast, recovers slowly, and [gives up on an address](state-machine.md#giving-up-an-address) that keeps failing.

### A routing daemon over two tunnels

The classic routing answer: give each pair of sites a direct tunnel as well as the path through the hub, and let Babel or BIRD pick by metric. It is robust and well understood, and if you already run a routing daemon between your sites, adding a direct tunnel there may be all you need.

It costs more moving parts: an extra interface and extra addresses for every pair of sites, a routing daemon on every node, and route changes on every switch. And it still does not know where the other site is. The direct tunnel's endpoint is static configuration, so when an ISP renumbers a site's IPv6 prefix, that tunnel dies until someone edits it.

wgpathd works the other way round. There is one tunnel per pair and routes never change; only the endpoint moves, and the hub publishes where each site currently is.

### A full overlay: Tailscale, Netmaker, Nebula, ZeroTier

These do far more than wgpathd: NAT traversal for pairs where neither side is reachable, key distribution, access control, many nodes joining and leaving. If you need any of that, use one of them.

The price is their own control plane, either a hosted service or a server you run (Headscale for Tailscale, the Netmaker server), and their own daemon, which is heavy on a router with little flash. They also replace your WireGuard configuration rather than steer it.

wgpathd is a deliberately small, self-hosted slice of the same pattern:

- **It steers the kernel WireGuard you already run.** There is no second overlay, no userspace WireGuard and no daemon from another ecosystem, just one ucode process.
- **It needs no outside control plane.** The coordinator is the hub reading its own WireGuard peer table and serving it over a tunnel you already trust. There are no accounts and no cloud service.
- **It stays small enough to read.** A daemon whose only action is `wg set ... endpoint` can be read in an afternoon, and it is tested end to end.

## What keeps it small

wgpathd makes one assumption: a pair of sites goes direct only when at least one side, the anchor, accepts inbound WireGuard over IPv6. The heavy machinery of the full overlays (STUN, hole punching, relay protocols) exists for pairs where neither side is reachable. With an anchor, the question shrinks to whether a round trip crosses the direct path. Many home connections that sit behind IPv4 carrier-grade NAT have public IPv6, so the assumption holds more often than it used to.

The other limit is scope. wgpathd changes endpoints and nothing else, so the worst a bug can do is send a peer to a bad address; it can never cut the hub tunnel you use to manage the router. See the [trust model](trust-model.md).

## When to choose something else

- **Neither site of a pair accepts inbound IPv6.** wgpathd keeps that pair on the hub, which is correct but gains nothing. A full overlay with NAT traversal can do better.
- **Many sites, or sites that come and go.** wgpathd expects peers, keys and AllowedIPs to be configuration you render yourself. An overlay that distributes them fits better.
- **You already run a routing daemon between sites.** Add a direct tunnel there instead of a second mechanism.
- **The hub is close, reliable and has bandwidth to spare, and you do not mind losing site-to-site traffic when it is down.** Staying on the hub is simpler.

For a handful of OpenWrt sites, a WireGuard hub you already run, and at least one site on public IPv6, wgpathd is the lighter choice.

## Further reading

- [About wgpathd](about.md) for how the direct and relay paths share one tunnel.
- [About the path state machine](state-machine.md) for how a spoke decides, and [what happens when things fail](state-machine.md#when-things-fail).
