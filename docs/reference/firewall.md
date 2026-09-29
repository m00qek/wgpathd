# Firewall Rules

The package installs one fw4 include:

```
/usr/share/nftables.d/chain-pre/input/wgpathd.nft
```

fw4 includes files from `chain-pre/input/` at the top of its `input` chain, before any zone rules. The file is the same on hubs and spokes; a rule that does not apply to a node's role matches nothing useful there. The package reloads the firewall (`/etc/init.d/firewall reload`) when it is installed, upgraded or removed, so the rules are loaded on install and gone after removal. When the package is built into a firmware image, the rules load with the firewall at first boot.

---

## Rules

| # | Rule | For | Purpose |
| :--- | :--- | :--- | :--- |
| 1 | `icmpv6 type echo-request accept` | spoke | Answer the underlay probe that other spokes send to this node's public IPv6 address. |
| 2 | `meta iifkind "wireguard" icmp type echo-request accept` | spoke | Answer the tunnel probe that other spokes send through `wg_mesh`. |
| 3 | `meta iifkind "wireguard" tcp dport 7780 accept` | hub | Accept connections to the discovery listener, which spokes reach through `wg_hub`. |
| 4 | `meta iifkind "wireguard" udp dport 51820 accept` | spoke | Accept relayed `wg_mesh` packets, which arrive out of the `wg_hub` interface. |

Each rule carries a comment starting with `wgpathd:`, so it can be found in `nft list ruleset`.

## Fixed names and ports

The rules do not follow the UCI configuration. They assume:

| Assumption | Rule | If yours differs |
| :--- | :--- | :--- |
| The tunnel probe uses IPv4 | 2 | An IPv6 `tunnel` address is covered by rule 1 instead. |
| The discovery listener uses port `7780` | 3 | Add a rule for your `serve_port`. |
| `wg_mesh` listens on UDP port `51820` | 4 | Add an equivalent rule for your listen port. |

## Scope

- **Rule 1** accepts ICMPv6 echo requests from any source on any interface.
- **Rules 2, 3 and 4** match only packets that came out of a WireGuard interface (`meta iifkind "wireguard"`), which only a peer holding a valid key can produce. They match on every WireGuard interface of the node, not only `wg_mesh` or `wg_hub`, and never on other interfaces such as WAN or LAN.
- Because the include is at the top of the `input` chain, zone rules cannot override these accepts.

The package does not open anything else. In particular, the `wg_mesh` listen port on WAN, for inbound-reachable sites and the hub, and forwarding between `wg_hub` peers on the hub, are part of your substrate. See [How to prepare the WireGuard substrate](../how-to/prepare-substrate.md).
