# Firewall Rules

The package ships no firewall rules and never changes the firewall. The operator adds the rules below to `/etc/config/firewall`, as [How to open the firewall for wgpathd](../how-to/open-firewall.md) shows, and `service wgpathd check` looks for them.

---

## What each role needs

| Role | Traffic | Arrives on | Rule |
| :--- | :--- | :--- | :--- |
| Spoke | ICMP echo request to the spoke's address on `mesh_iface`; ICMPv6 when that address is IPv6 | The zone of `mesh_iface` | [Tunnel probe](#tunnel-probe) |
| Spoke | UDP to the `listen_port` of `mesh_iface` | The zone of `hub_iface` | [Relayed packets](#relayed-packets) |
| Spoke | ICMPv6 echo request to the spoke's public IPv6 address | The `wan` zone | [Underlay probe](#underlay-probe): OpenWrt's `Allow-ICMPv6-Input` |
| Hub | TCP to `serve_port` on `serve_addr` | The zone of the WireGuard interface that holds `serve_addr` | [Peer list](#peer-list) |

Nothing else is needed for wgpathd. Answers to what a node sends, the echo replies to its probes and the reply to its peer list request, are accepted as part of an established connection. What WireGuard itself needs, the listen ports from WAN and forwarding between the hub's `wg_hub` peers, is part of the substrate: see [How to prepare the WireGuard substrate](../how-to/prepare-substrate.md).

A zone whose input policy is `ACCEPT` already accepts all of it.

## The rules

### Tunnel probe

```
config rule
	option name 'Allow-wgpathd-tunnel-probe'
	option src 'vpn'
	option proto 'icmp'
	option icmp_type 'echo-request'
	option family 'ipv4'
	option target 'ACCEPT'
```

Every cycle, each other spoke pings this spoke's tunnel address through `wg_mesh`: to test a direct path, and then to keep checking it. Without an answer, no trial succeeds and a peer on a direct path falls back to the relay. `src` is the zone of `mesh_iface`. The probe goes to the address the other spokes have as this spoke's `tunnel`; `family` is that address's, and is left out when `mesh_iface` has addresses of both families.

### Relayed packets

```
config rule
	option name 'Allow-wgpathd-relay'
	option src 'vpn'
	option proto 'udp'
	option dest_port '51820'
	option target 'ACCEPT'
```

When a pair uses the relay, the other spoke sends its `wg_mesh` packets to this spoke's relay endpoint, its transit address and `wg_mesh` listen port. The hub forwards them, and they arrive out of `hub_iface`, addressed to that port. Without the rule the relay works only in the direction this spoke opened first. `src` is the zone of `hub_iface`, and `dest_port` the `listen_port` of `mesh_iface` in `/etc/config/network`.

### Underlay probe

Each other spoke pings this spoke's public IPv6 address from the internet, for evidence that a direct path may work. OpenWrt's default configuration accepts this with its rule `Allow-ICMPv6-Input` on `wan`, limited to 1000 packets a second, and wgpathd needs no rule of its own. A spoke that does not answer gets no direct path from the others' evidence; the others may still reach it after it contacts them.

### Peer list

```
config rule
	option name 'Allow-wgpathd-discovery'
	option src 'vpn'
	option proto 'tcp'
	option dest_port '7780'
	option target 'ACCEPT'
```

The spokes fetch the peer list from the hub's `serve_addr` and `serve_port`, through the hub tunnel. `src` is the zone of the WireGuard interface that holds `serve_addr`, and `dest_port` is `serve_port`. Accepting the port from another zone opens the list to whatever that zone reaches.

## What the check confirms

On a live system, `service wgpathd check` and the [ubus config check](ubus-config-check.md) read `/etc/config/firewall` and, for each traffic of the role, say whether it is accepted (`ok`), not accepted (`warn`, with the rule to add) or cannot be confirmed (`warn`). `check.uc --config`, which `start` and `reload` run, does not look at the firewall. Without `/etc/config/firewall` the check says `skip  firewall: no /etc/config/firewall, not checked`. The findings are listed in [Service commands](service-commands.md#findings).

It reads the configuration the way fw4 does:

- **The zone** of an interface is the first enabled zone whose `network` lists it. A zone with a name fw4 would refuse is skipped.
- **The rules** that apply are enabled `rule` sections without `dest`: first those with `src '*'`, then those of the zone, in the order of the file. The first rule whose `target` is `ACCEPT`, `REJECT` or `DROP` and that covers the traffic decides. Without one, the zone's `input` decides, or the `input` of `defaults` when the zone has none. An interface in no zone gets only the `src '*'` rules and the default `input`.
- **A rule covers the traffic** when its `family`, or its zone's when it has none, includes the traffic's; its `proto` names the protocol (unset means TCP and UDP; `all`, `tcpudp`, protocol numbers, and `icmp` for ICMPv6 too unless the family says otherwise); its `dest_port` includes the port (a port, a range `a-b` or `a:b`, or a list; unset is every port); and its `icmp_type` includes an echo request (`echo-request`, `ping`, `8` or `8/0`, `128` for ICMPv6; unset is every type). Lists may be UCI lists or words in one option. A `limit` does not stop a rule from accepting.

It **could not confirm** a traffic, rather than call it missing, when:

- a rule that may decide it has options the check does not follow: `src_ip`, `src_mac`, `src_port`, `dest_ip`, `device`, `ipset`, `helper`, `mark`, `dscp`, a time restriction or `extra`, or an inverted (`!`) or unreadable protocol or port, or it is an ICMP rule for both families that names only other types;
- the zone has `extra_src` or `extra`, or its `family` excludes the traffic's;
- a zone that matches by `device` or `subnet` comes before the interface's zone, or no zone lists the interface and one matches that way;
- the firewall has custom nftables rules: an enabled `include` section, or a file with anything but comments in `/etc/nftables.d/*.nft`, `/usr/share/nftables.d/ruleset-*/`, `/usr/share/nftables.d/table-*/` or `/usr/share/nftables.d/chain-*/input*/`;
- `mesh_iface` has no `listen_port`, so the relay port is not known;
- there is no zone named `wan`, for the underlay probe.

It does not see rules that other services add at runtime through procd, nor tables other than fw4's. Those cannot accept what fw4 rejects, but they can drop what it accepts.

Every firewall finding is a warning, never `FAIL`: a custom firewall may accept the traffic in ways the check cannot see, so neither the service nor LuCI's Save & Apply refuses a configuration over it. A warning names the wgpathd option the traffic follows from, `mesh_iface`, `hub_iface` or `serve_port`, and, when there is a zone to name and a port, carries the rule to add as uci commands and as a section of `/etc/config/firewall`. The rule to add for an interface in no zone is to put it in one.

## Releases up to 5

Releases up to 5 installed an fw4 include, `/usr/share/nftables.d/chain-pre/input/wgpathd.nft`, which put four accepts at the top of the `input` chain, before any zone rule: ICMPv6 echo requests from anywhere, without a rate limit, and ICMP echo requests, TCP `7780` and UDP `51820` from every WireGuard interface. They bypassed the operator's zone policy, and the first let a flood from the internet keep the daemon busy.

An upgrade removes the file, and the package's post-install script reloads the firewall once while rules with a `wgpathd:` comment are still loaded, so they leave the running ruleset too. Add the rules above **before** upgrading such a node: from the reload on, a zone that rejects input rejects wgpathd's traffic until they are there.
