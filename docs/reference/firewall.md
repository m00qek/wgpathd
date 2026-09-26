# Firewall Rules

The package installs one fw4 include:

```
/usr/share/nftables.d/chain-pre/input/wgpathd.nft
```

fw4 includes files from `chain-pre/input/` at the top of its `input` chain, before any zone rules. The file is the same on hubs and spokes; a rule that does not apply to a node's role matches nothing useful there. fw4 picks the file up the next time the firewall is reloaded (`service firewall reload`); installing the package does not reload it.

---

## Rules

| # | Rule | For | Purpose |
| :--- | :--- | :--- | :--- |
| 1 | `icmpv6 type echo-request accept` | spoke | Answer the underlay probe that other spokes send to this node's public IPv6 address. |
| 2 | `iifname "wg_mesh" icmp type echo-request accept` | spoke | Answer the tunnel probe that other spokes send through `wg_mesh`. |
| 3 | `tcp dport 7780 accept` | hub | Accept connections to the discovery listener. |
| 4 | `meta iifkind "wireguard" udp dport 51820 accept` | spoke | Accept relayed `wg_mesh` packets, which arrive out of the `wg_hub` interface. |

Each rule carries a comment starting with `wgpathd:`, so it can be found in `nft list ruleset`.

## Fixed names and ports

The rules do not follow the UCI configuration. They assume:

| Assumption | Rule | If yours differs |
| :--- | :--- | :--- |
| The mesh interface is named `wg_mesh` | 2 | Add an equivalent rule for your interface. |
| The tunnel probe uses IPv4 | 2 | An IPv6 `wgpathd_tunnel` is covered by rule 1 instead. |
| The discovery listener uses port `7780` | 3 | Add a rule for your `serve_port`. |
| `wg_mesh` listens on UDP port `51820` | 4 | Add an equivalent rule for your listen port. |

## Scope

- **Rule 1** accepts ICMPv6 echo requests from any source on any interface.
- **Rule 3** accepts TCP port 7780 on **every interface, including WAN**, on every node where the package is installed. The discovery listener itself only binds `serve_addr`, and only runs on the hub. Because the include is at the top of the `input` chain, zone rules cannot override the accept.
- **Rule 4** matches only packets that came out of a WireGuard interface, which only a peer holding a valid key can produce. It accepts UDP port 51820 from any WireGuard interface, not only `wg_hub`.

The package does not open anything else. In particular, the `wg_mesh` listen port on WAN, for inbound-reachable sites and the hub, and forwarding between `wg_hub` peers on the hub, are part of your substrate. See [How to prepare the WireGuard substrate](../how-to/prepare-substrate.md).
