# How to Open the Firewall for wgpathd

The wgpathd package ships no firewall rules. This guide adds the few that wgpathd needs, as ordinary traffic rules in `/etc/config/firewall`, and confirms them with `service wgpathd check`. Do it on every node, before you turn wgpathd on.

!!! warning "Upgrading from release 5 or earlier"
    Releases up to 5 loaded these accepts themselves, from a firewall include that the upgrade removes. Add the rules below **before** you upgrade such a node. Otherwise, once the upgrade reloads the firewall, a zone that rejects input rejects wgpathd's probes, relayed packets and peer list, and every peer falls back to the relay, or loses the relay too.

The examples follow [How to prepare the WireGuard substrate](prepare-substrate.md): `wg_mesh` and `wg_hub` are both in a zone called `vpn`, `wg_mesh` listens on UDP `51820`, and the hub publishes its peer list on `10.10.0.1:7780`. Use your own zone names and ports.

## What each role needs

| Role | Traffic | Arrives on | Rule |
| :--- | :--- | :--- | :--- |
| Spoke | ICMP echo requests: the other spokes' tunnel probes | The zone of `mesh_iface` | `Allow-wgpathd-tunnel-probe` |
| Spoke | UDP to the `wg_mesh` listen port: relayed WireGuard packets | The zone of `hub_iface` | `Allow-wgpathd-relay` |
| Spoke | ICMPv6 echo requests: the other spokes' underlay probes | The `wan` zone | OpenWrt's own `Allow-ICMPv6-Input`, which a default configuration has: keep it |
| Hub | TCP to `serve_port`: the spokes' peer list requests | The zone of the interface that holds `serve_addr` | `Allow-wgpathd-discovery` |

A zone whose input policy is already `ACCEPT` needs no rule. Why each one is needed, and what the check can confirm, is in [Firewall rules](../reference/firewall.md).

WireGuard itself needs its listen ports open from WAN; [How to prepare the WireGuard substrate](prepare-substrate.md) does that, and it is not repeated here.

---

## 1. Find the zones of the interfaces

```bash
uci show firewall | grep -e '\.name=' -e '\.network=' -e '\.device='
```

```
firewall.@zone[0].name='lan'
firewall.@zone[0].network='lan'
firewall.@zone[1].name='wan'
firewall.@zone[1].network='wan' 'wan6'
firewall.@zone[2].name='vpn'
firewall.@zone[2].network='wg_hub' 'wg_mesh'
```

A zone may name devices instead, as in `firewall.@zone[2].device='wg_hub' 'wg_mesh'`: a WireGuard interface's device has the interface's name, so that zone holds both interfaces too. In LuCI the same is under **Network → Firewall**, in the **Zones** list. If an interface is in no zone, add it to one first, under **Network → Firewall → Zones**, **Edit**, **Covered networks**, or with `uci add_list firewall.@zone[2].network='wg_mesh'`.

## 2. Add the rules of a spoke

=== "LuCI"

    Go to **Network → Firewall → Traffic Rules** and click **Add** for each rule:

    | Field | Tunnel probe | Relayed packets |
    | :--- | :--- | :--- |
    | **Name** | `Allow-wgpathd-tunnel-probe` | `Allow-wgpathd-relay` |
    | **Protocol** | ICMP | UDP |
    | **Source zone** | the zone of `wg_mesh` | the zone of `wg_hub` |
    | **Destination zone** | **Device (input)** | **Device (input)** |
    | **Destination port** | — | `51820` |
    | **Action** | accept | accept |
    | **Advanced Settings → Restrict to address family** | IPv4 only | — |
    | **Advanced Settings → Match ICMP type** | `echo-request` | — |

    Click **Save**, then **Save & Apply**.

=== "uci"

    ```bash
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-wgpathd-tunnel-probe'
    uci set firewall.@rule[-1].src='vpn'
    uci set firewall.@rule[-1].proto='icmp'
    uci set firewall.@rule[-1].icmp_type='echo-request'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].target='ACCEPT'

    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-wgpathd-relay'
    uci set firewall.@rule[-1].src='vpn'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='51820'
    uci set firewall.@rule[-1].target='ACCEPT'

    uci commit firewall
    service firewall reload
    ```

=== "/etc/config/firewall"

    ```
    config rule
    	option name 'Allow-wgpathd-tunnel-probe'
    	option src 'vpn'
    	option proto 'icmp'
    	option icmp_type 'echo-request'
    	option family 'ipv4'
    	option target 'ACCEPT'

    config rule
    	option name 'Allow-wgpathd-relay'
    	option src 'vpn'
    	option proto 'udp'
    	option dest_port '51820'
    	option target 'ACCEPT'
    ```

    Then run `service firewall reload`.

- The tunnel probe goes to the spoke's own address on `wg_mesh`. If that address is IPv6, choose **IPv6 only** (`family 'ipv6'`) instead; if the interface has addresses of both families, leave the family out.
- The relay rule's port is the `listen_port` of this spoke's own `wg_mesh`, the port the other spokes put in its relay endpoint.
- If `wg_mesh` and `wg_hub` are in different zones, give each rule the zone of its own interface.

A new rule goes to the end of the list. If a rule above it rejects the same traffic, move the new one above that rule: in LuCI, drag it; the check says when this is the case.

## 3. Keep OpenWrt's ICMPv6 rule on a spoke

Other spokes find out whether a spoke's public IPv6 address answers by pinging it, from the internet. OpenWrt's default configuration accepts that ICMPv6 echo request on `wan` with its rule `Allow-ICMPv6-Input`, rate-limited to 1000 packets a second, so wgpathd needs no rule of its own for it.

Check that the rule is still there: **Allow-ICMPv6-Input** in the **Traffic Rules** list, with **Enable** ticked and `echo-request` among its ICMP types. If you removed or narrowed it, restore it. The check in step 5 confirms it too.

## 4. Add the rule of the hub

=== "LuCI"

    Go to **Network → Firewall → Traffic Rules** and click **Add**:

    | Field | Value |
    | :--- | :--- |
    | **Name** | `Allow-wgpathd-discovery` |
    | **Protocol** | TCP |
    | **Source zone** | the zone of `wg_hub`, the interface that holds `serve_addr` |
    | **Destination zone** | **Device (input)** |
    | **Destination port** | `7780`, your `serve_port` |
    | **Action** | accept |

    Click **Save**, then **Save & Apply**.

=== "uci"

    ```bash
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-wgpathd-discovery'
    uci set firewall.@rule[-1].src='vpn'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='7780'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    service firewall reload
    ```

=== "/etc/config/firewall"

    ```
    config rule
    	option name 'Allow-wgpathd-discovery'
    	option src 'vpn'
    	option proto 'tcp'
    	option dest_port '7780'
    	option target 'ACCEPT'
    ```

    Then run `service firewall reload`.

Accept the port from the hub tunnel's zone only. From any other zone, the peer list would be open to whatever that zone reaches.

## 5. Confirm with the check

Once wgpathd has a role, `service wgpathd check` looks for each of these rules. On a spoke:

```bash
service wgpathd check
```

```
ok    config: spoke, mode observe, 1 steered peer, 1 not steered
ok    wg_mesh: up, 2 peers
ok    wg_hub: up, 1 peer
ok    peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12
skip  peer hub: not steered (not configured)
ok    firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): accepted
ok    firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): accepted
ok    firewall: ICMPv6 echo-request (underlay probe) from zone wan: accepted
```

On the hub, the last line is `ok    firewall: TCP port 7780 (peer list) from wg_hub (zone vpn): accepted`.

A rule that is missing gives a `warn` line instead, followed by the rule to add, both as uci commands and as the section of `/etc/config/firewall`:

```
warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it
      add it with:
        uci add firewall rule
        uci set firewall.@rule[-1].name='Allow-wgpathd-relay'
        ...
```

The **Check configuration** button of **Network → Mesh paths** in LuCI shows the same lines, with the rule under each warning.

`could not confirm` means the check cannot tell, for example because a rule has conditions it does not follow, or the firewall has custom nftables rules. The traffic may well be accepted: look at the rule or the custom rules it names, or add the rule it suggests to be sure. The firewall findings are never `FAIL`, so they do not stop the service or LuCI's Save & Apply. Every message is listed in [Service commands](../reference/service-commands.md#findings).
