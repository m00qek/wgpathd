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
| A peer's `public_key`, `wgpathd_relay` and `wgpathd_tunnel` all unchanged | The peer keeps its state, counters and switch count. A peer rejected with `relay routes into <mesh_iface>` is guarded again, and becomes managed, starting in RELAY, if its route was fixed. |
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
  hub  HubMeshP  missing wgpathd_relay
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
skip  peer hub: not steered (missing wgpathd_relay)
FAIL  peer spoke_c: not steered (invalid wgpathd_relay)
```

### Findings

| Level | Line | When |
| :--- | :--- | :--- |
| `ok` | `config: spoke, mode <mode>, <n> steered peer(s), <n> not steered` | A valid spoke configuration. "Steered" counts peers with valid annotations, before the route check. |
| `ok` | `config: hub, reads <read_iface>, serves <addr>:<port>` | A valid hub configuration. |
| `FAIL` | `config: option role must be 'spoke' or 'hub' (is <value>)` | `role` is missing or wrong. `<value>` is `unset` when missing. |
| `FAIL` | `config: missing option <name>` | A required option is missing or empty. |
| `FAIL` | `config: no interface <name> in /etc/config/network` | An interface option names no `interface` section. |
| `FAIL` | `config: option <name> must be an interface name of letters, digits and _` | `mesh_iface`, `hub_iface` or `read_iface` is not a plain section name. |
| `FAIL` | `config: option <name> must be a positive number` | A timing parameter is invalid. |
| `warn` | `config: unknown mode '<mode>' runs as observe` | `mode` is neither `steer` nor `observe`. |
| `warn` | `service disabled (option enabled '<value>'): it will not start` | `enabled` is off. |
| `skip` | `ubus unavailable: interfaces not checked` | ubus cannot be reached. The interface lines are left out; the peer lines still appear. |
| `ok` | `<iface>: up, <n> peer(s)` | The interface is in the `wireguard status` reply. |
| `FAIL` | `<iface>: <reason>` | `mesh_iface` or `read_iface` is not in the `wireguard status` reply, or the reply cannot be read. |
| `warn` | `<hub_iface>: <reason>` | The same, for `hub_iface`. |
| `ok` | `peer <section>: relay <relay> via <oif>, probes <tunnel>` | The peer is managed; the route to its relay host leaves via `<oif>`. |
| `FAIL` | `peer <section>: relay routes into <mesh_iface>` | The relay host routes into the mesh. |
| `warn` | `peer <section>: relay route lookup failed: <CODE> (<detail>) (retried every cycle)` | No route to the relay host yet. |
| `warn` | `peer <section>: not in <mesh_iface> yet, skipped until it appears` | The peer is managed but not in the kernel's peer table. |
| `skip` | `peer <section>: not steered (missing <option>)` | The peer has no `wgpathd_relay` or no `wgpathd_tunnel`, such as the hub peer. |
| `FAIL` | `peer <section>: not steered (invalid <option>)` | A `public_key`, `wgpathd_relay` or `wgpathd_tunnel` is malformed. |

The peer reasons are the ones in [Substrate annotations](substrate.md#managed-and-unmanaged-peers).

The same findings, apart from the interface lines, are available over ubus, also for values not saved yet: see [ubus config check](ubus-config-check.md).

### `--config`

`/usr/libexec/wgpathd/check.uc --config` runs only the configuration findings: the `config:` lines, without the `enabled` warning, ubus or routes. It is what `start` and `reload` run. Any other argument prints `usage: check.uc [--config]` on standard error and exits with `2`.
