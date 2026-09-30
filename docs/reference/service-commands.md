# Service Commands

wgpathd is run and inspected through its init script, `/etc/init.d/wgpathd`, usually as `service wgpathd <command>`. Nothing is installed on the `PATH`.

| Command | Effect |
| :--- | :--- |
| `start` | Starts the daemon, if `enabled` is on and the configuration passes the config check. See [start](#start). |
| `stop` | Stops the daemon. |
| `restart` | `stop`, then `start`. Every peer starts again in RELAY. |
| `reload` | Applies a changed configuration to the running daemon. See [reload](#reload). |
| `status` | Prints procd's state and, while running, a readable summary. See [status](#status). |
| `check` | Validates the configuration and the substrate. See [check](#check). |
| `migrate` | Moves peer settings left in `/etc/config/network` by releases up to 4 into `/etc/config/wgpathd`. See [migrate](#migrate). |
| `enable` / `disable` | Adds or removes the boot-time start link, `/etc/rc.d/S95wgpathd`. |

---

## `start`

1. If `option enabled` in `main` is off, `start` registers the service with no instance and returns `0`. The daemon does not run.
2. Otherwise it runs the config check, `/usr/libexec/wgpathd/check.uc --config`. If that fails, the report and `invalid configuration, not starting` go to standard error and to syslog at `daemon.err`, no instance is created, and `start` returns `1`. Nothing respawns.
3. Otherwise procd starts `/usr/libexec/wgpathd/daemon.uc` as the instance `wgpathd`.

The config check only reads UCI. A failure that needs the running system, such as a WireGuard interface that is not up, still happens in the daemon, which then exits and is respawned every 5 seconds. See [Log messages](log-messages.md#startup-and-exit).

## `reload`

| Situation | Effect |
| :--- | :--- |
| `enabled` is off | Same as `start`: the service is left with no instance, so a running daemon stops. |
| The daemon is not running | Same as `start`. |
| The daemon is running | Runs the config check. If it passes, sends `SIGHUP` to the daemon. If it fails, the report and `invalid configuration, keeping the running one` go to standard error and to syslog, and the running daemon keeps its configuration. Returns `1`. |

procd runs `reload` by itself when it receives a `config.change` event for the `wgpathd` or `network` package. LuCI's Save & Apply and `reload_config` send that event; `uci commit` alone does not.

On `SIGHUP` the daemon reads `/etc/config/wgpathd` and `/etc/config/network` again:

| What changed | Effect |
| :--- | :--- |
| `role`, `mesh_iface`, `hub_iface`, `read_iface`, `serve_addr` or `serve_port` | The daemon logs `reload: exiting for procd to start afresh changed=<option>` and exits. procd starts it again after 5 seconds, and every peer starts in RELAY. |
| Timing parameters | Apply from the next cycle. |
| `mode` | Applies from the next cycle. Switching to `observe` demotes TRIALING and DIRECT peers to RELAY. |
| `discovery` | The new URL is fetched on the next cycle. The discovery map already held is kept until then. |
| A peer's `public_key`, `relay` and `tunnel` all unchanged | The peer keeps its state, counters and switch count. A peer rejected with `relay routes into <mesh_iface>` is guarded again, and becomes managed, starting in RELAY, if its route was fixed. |
| A peer added, or one of those three options changed | The peer is checked like at startup and, if managed, starts in RELAY. |
| A peer removed | It leaves steering and the status. Its endpoint is left as it is. |

A spoke logs `configuration reloaded peers_kept=<n> added=<n> removed=<n>`, with ` mode=<mode>` appended when the mode changed; a hub logs `configuration reloaded`. If the configuration is invalid when the daemon reads it, it logs `reload: invalid configuration, keeping the running one: <CODE> (<detail>)` and keeps running unchanged.

## `status`

The first line is procd's state of the service, and the exit status is procd's:

| First line | Exit status | Meaning |
| :--- | :--- | :--- |
| `running` | `0` | The daemon runs. |
| `active with no instances` | `0` | The service is registered without a daemon, for example because `enabled` is off. |
| `inactive` | `3` | The service is not registered with procd: stopped, or never started. |
| `not running` | `5` | The instance exists but its process is not running, for example between respawns. |

If `enabled` is off, the next line is `disabled (option enabled in /etc/config/wgpathd)`. If the daemon runs, a summary of [`ubus call wgpathd status`](ubus-status.md) follows. If that call fails, `wgpathd: cannot read status: <CODE>` goes to standard error; the exit status is still procd's.

On a spoke:

```
running
role: spoke (mode steer)
discovery: fresh (last success 42s ago)
peers:
  spoke_b  SpokeBme  DIRECT  [2001:db8:b::20]:51820  5m ago (trial_ok)  2 switches
  spoke_c  SpokeCme  RELAY   10.10.0.13:51820        no change yet      0 switches
unmanaged:
  hub  HubMeshP  fixed endpoint
```

| Line | Content |
| :--- | :--- |
| `role:` | The role and the mode. |
| `discovery:` | `fresh` or `stale`, and the age of the last successful fetch, or `never succeeded`. |
| `peers:` | One line per managed peer, sorted by section: section, first 8 characters of the public key, state, asserted endpoint, age and reason of the last transition, and the switch count. `peers: none` when there are none. |
| `unmanaged:` | One line per unmanaged peer: section, key prefix, reason. Left out when there are none. |

On a hub:

```
running
role: hub
published peers:
  SpokeAme  [2001:db8:a::1]:51820   handshake 12s ago
  SpokeBme  [2001:db8:b::20]:51820  handshake 7s ago
```

Each line is a key prefix, the published direct endpoint and the handshake age. `published peers: none` when the snapshot is empty.

Ages are shown in whole seconds, minutes, hours or days: `42s`, `5m`, `3h`, `2d`.

## `check`

```bash
service wgpathd check
```

It runs `/usr/libexec/wgpathd/check.uc`, which loads the configuration with the daemon's own loader and then checks the substrate the daemon needs. It changes nothing and works whether or not the daemon runs. Each finding is one line with a level:

| Level | Meaning |
| :--- | :--- |
| `ok` | The item is as it should be. |
| `skip` | The item was not checked, or is deliberately not steered. |
| `warn` | The daemon runs, but something is off or not ready yet. |
| `FAIL` | The daemon cannot start, or the item is a configuration mistake. |

The exit status is `1` if any line is `FAIL`, `0` otherwise.

```
ok    config: spoke, mode observe, 1 steered peer, 2 not steered
ok    wg_mesh: up, 3 peers
ok    wg_hub: up, 1 peer
ok    peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12
skip  peer hub: not steered (fixed endpoint)
FAIL  peer spoke_c: not steered (invalid relay)
ok    firewall: ICMP echo-request (tunnel probe) from wg_mesh (zone vpn): accepted
warn  firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it
      add it with:
        uci add firewall rule
        uci set firewall.@rule[-1].name='Allow-wgpathd-relay'
        uci set firewall.@rule[-1].src='vpn'
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].dest_port='51820'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        service firewall reload
      or in /etc/config/firewall:
        config rule
        	option name 'Allow-wgpathd-relay'
        	option src 'vpn'
        	option proto 'udp'
        	option dest_port '51820'
        	option target 'ACCEPT'
ok    firewall: ICMPv6 echo-request (underlay probe) from zone wan: accepted
```

A firewall warning that can name the rule to add is followed by it, indented, both as uci commands and as a section of `/etc/config/firewall`.

### Findings

| Level | Line | When |
| :--- | :--- | :--- |
| `ok` | `config: spoke, mode <mode>, <n> steered peer(s), <n> not steered` | A valid spoke configuration. "Steered" counts peers with valid settings, before the route check. |
| `ok` | `config: hub, reads <read_iface>, serves <addr>:<port>` | A valid hub configuration. |
| `FAIL` | `config: option role must be 'spoke' or 'hub' (is <value>)` | `role` is missing or wrong. `<value>` is `unset` when missing. |
| `FAIL` | `config: missing option <name>` | A required option is missing or empty. |
| `FAIL` | `config: no interface <name> in /etc/config/network` | An interface option names no `interface` section. |
| `FAIL` | `config: option <name> must be an interface name of letters, digits and _` | `mesh_iface`, `hub_iface` or `read_iface` is not a plain section name. |
| `FAIL` | `config: option discovery must be a URL of the form http://<host>[:<port>]/<path>` | `discovery` is not an `http://` URL with a host, see [UCI configuration](uci-config.md#spoke-options). |
| `FAIL` | `config: option serve_addr must be an IP address of the router, not unspecified or multicast` | `serve_addr` is not one literal address a listener can bind, see [UCI configuration](uci-config.md#hub-options). |
| `FAIL` | `config: option serve_port must be a port number from 1 to 65535` | `serve_port` is not a decimal port number. |
| `FAIL` | `config: option <name> must be a number from <min> to <max>`, `config: option <name> must be a whole number from <min> to <max>` | A timing parameter is not a decimal number within its [bounds](parameters.md#bounds). |
| `FAIL` | `config: option backoff_max must be at least backoff_min (<value>)`, `config: option trial_window must be longer than cycle + tunnel_timeout (<sum>)` | On a spoke, two timing parameters disagree. |
| `warn` | `config: unknown mode '<mode>' runs as observe` | `mode` is neither `steer` nor `observe`. |
| `warn` | `service disabled (option enabled '<value>'): it will not start` | `enabled` is off. |
| `warn` | `config: discovery host <name> is a name, not an address: every fetch waits for DNS` | The `discovery` URL names its host. The fetch looks it up without letting the daemon run meanwhile. |
| `warn` | `config: discovery host <addr> routes via <oif>, not <hub_iface>` | The route to the discovery host does not leave via `hub_iface`, so discovery would stop with the path it goes over. Not checked with `--config`. |
| `warn` | `config: discovery host <addr>: route lookup failed: <CODE> (<detail>)` | No route to the discovery host. Not checked with `--config`. |
| `warn` | `config: serve_addr <addr> is no address of a WireGuard interface in /etc/config/network` | On a hub, no `interface` section with `proto 'wireguard'` lists `serve_addr` in its `addresses`. The discovery server then answers wherever the firewall lets that address be reached, and the check looks for no firewall rule for it; see [Firewall rules](firewall.md#peer-list). Not checked with `--config`. |
| `warn` | `config: network section <section>: <options> left over from an earlier version, ignored; run service wgpathd migrate or remove it` | The section still has `wgpathd_relay`, `wgpathd_tunnel` or both, which releases up to 4 read and this one does not. `<options>` names them, joined by `and`; with two, the line ends `remove them`. See [How to upgrade from a release that kept peer settings in the network configuration](../how-to/upgrade-peer-settings.md). |
| `warn` | `peer settings for <key>: no such peer in <mesh_iface>, ignored` | On a spoke, a `peer` section's `public_key` is the key of no `wireguard_<mesh_iface>` section. |
| `warn` | `peer settings without a public_key: ignored` | On a spoke, a `peer` section has no `public_key`. |
| `skip` | `ubus unavailable: interfaces not checked` | ubus cannot be reached. The interface lines are left out; the peer lines still appear. |
| `ok` | `<iface>: up, <n> peer(s)` | The interface is in the `wireguard status` reply. |
| `FAIL` | `<iface>: <reason>` | `mesh_iface` or `read_iface` is not in the `wireguard status` reply, or the reply cannot be read. |
| `warn` | `<hub_iface>: <reason>` | The same, for `hub_iface`. |
| `ok` | `peer <section>: relay <relay> via <oif>, probes <tunnel>` | The peer is managed; the route to its relay host leaves via `<oif>`. |
| `FAIL` | `peer <section>: relay routes into <mesh_iface>` | The relay host routes into the mesh. |
| `warn` | `peer <section>: relay route lookup failed: <CODE> (<detail>) (retried every cycle)` | No route to the relay host yet. |
| `warn` | `peer <section>: not in <mesh_iface> yet, skipped until it appears` | The peer is managed but not in the kernel's peer table. |
| `skip` | `peer <section>: not steered (fixed endpoint)` | No `peer` section has the peer's key, and it has an `endpoint_host` in `/etc/config/network`, as the hub peer does. |
| `skip` | `peer <section>: not steered (not configured)` | No `peer` section has the peer's key, and it has no `endpoint_host`. |
| `FAIL` | `peer <section>: not steered (configured more than once)` | Two or more `peer` sections have the peer's key. |
| `FAIL` | `peer <section>: not steered (missing <option>)` | The peer's `peer` section has no `relay` or no `tunnel`. |
| `FAIL` | `peer <section>: not steered (invalid <option>)` | The peer's `public_key` in `/etc/config/network`, or the `relay` or `tunnel` of its `peer` section, is malformed. |

The peer reasons are the ones in [Managed and unmanaged peers](uci-config.md#managed-and-unmanaged-peers).

The firewall lines come last, one for each traffic the role needs accepted, as [Firewall rules](firewall.md#what-the-check-confirms) describes. They are not checked with `--config`.

| Level | Line | When |
| :--- | :--- | :--- |
| `ok` | `firewall: <traffic> from <source>: accepted` | A rule, or the zone's input policy, accepts the traffic. |
| `warn` | `firewall: <traffic> from <source>: no rule accepts it` | No rule accepts it, and the zone's policy rejects or drops it. The rule to add follows. |
| `warn` | `firewall: <traffic> from <source>: a rule rejects it before any accepts it` | A rule with `target 'REJECT'` or `'DROP'` decides it first. The rule to add follows; place it above the one that rejects. |
| `warn` | `firewall: <traffic> from <iface> (no zone): no rule accepts it; put <iface> in a firewall zone` | The interface is in no zone, and the default input policy rejects the traffic. |
| `warn` | `firewall: ICMPv6 echo-request (underlay probe) from zone wan: no rule accepts it: restore OpenWrt's default rule Allow-ICMPv6-Input` | On a spoke, nothing accepts ICMPv6 echo requests from `wan`. |
| `warn` | `firewall: <traffic> from <source>: could not confirm, <reason>` | The check cannot tell. The rule to add follows when there is a zone and a port to name it by. |
| `skip` | `firewall: no /etc/config/firewall, not checked` | There is no firewall configuration. |

`<traffic>` is one of:

| `<traffic>` | Role | `option` of the finding over ubus |
| :--- | :--- | :--- |
| `ICMP echo-request (tunnel probe)`, `ICMPv6 echo-request (tunnel probe)` | Spoke, one line for each address family of `mesh_iface` | `mesh_iface` |
| `UDP port <listen_port> (relayed WireGuard)`, or `UDP (relayed WireGuard)` without a `listen_port` | Spoke | `hub_iface` |
| `ICMPv6 echo-request (underlay probe)` | Spoke | none |
| `TCP port <serve_port> (peer list)` | Hub, when a WireGuard interface holds `serve_addr` | `serve_port` |

`<source>` is `<iface> (zone <zone>)`, `<iface> (no zone)` or, for the underlay probe, `zone wan`. `<reason>` is one of:

| `<reason>` | Cause |
| :--- | :--- |
| `a rule or zone option this check does not follow applies` | A rule that may decide the traffic, or the zone, has an option the check does not follow, such as `src_ip` or `extra_src`. |
| `the firewall has custom nftables rules` | An `include` section, or an nftables file fw4 includes, may add rules the check cannot read. |
| `a zone may take it by device or subnet` | A zone that matches by `subnet`, or by a `network` or `device` the check does not follow, such as an inverted one, may take the traffic before the interface's own. See [Firewall rules](firewall.md#what-the-check-confirms). |
| `zone <zone> is not for IPv<n>` | The zone's `family` excludes the traffic's. |
| `<mesh_iface> has no listen_port` | The relay port is not fixed, so it cannot be looked for. |
| `no such zone` | There is no zone named `wan`. |

The same findings, apart from the interface lines, are available over ubus, also for values not saved yet: see [ubus config check](ubus-config-check.md).

### `--config`

`/usr/libexec/wgpathd/check.uc --config` runs only the configuration findings: the `config:` lines, including the options left over in `/etc/config/network`, and the `peer settings` warnings, without the `enabled` warning, ubus, routes, the firewall or the other peer lines. It is what `start` and `reload` run. Any other argument prints `usage: check.uc [--config]` on standard error and exits with `2`.

## `migrate`

```bash
service wgpathd migrate
```

It runs `/usr/libexec/wgpathd/migrate.uc`, the program the package's uci-defaults script runs after an install or upgrade: it moves the options `wgpathd_relay` and `wgpathd_tunnel` of every WireGuard peer section in `/etc/config/network` into the `peer` section with that peer's key in `/etc/config/wgpathd`, keeping any value already there, and commits both files. What it does, step by step, is in [Files and dependencies](files.md#etcuci-defaults50-wgpathd-peers).

Its messages go to syslog, and to standard error when run from a terminal; see [Log messages](log-messages.md#migration). The exit status is `0` when everything was moved or there was nothing to move, and `1` when a step failed, in which case `/etc/config/network` is left as it was. It does not reload the daemon: run `service wgpathd reload` afterwards.
