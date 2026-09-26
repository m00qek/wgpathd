# Log Messages

wgpathd logs to syslog with the identifier `wgpathd`, its PID, and facility `daemon`.

```bash
logread -e wgpathd
```

A line looks like this:

```
Sun Sep 27 10:15:03 2026 daemon.info wgpathd[2481]: peer SpokeBmeshPublicKeyExample00000000000000000=: transition RELAY -> TRIALING (trial_start)
```

wgpathd uses three levels:

| Level | syslog priority | Shown by `logread` as |
| :--- | :--- | :--- |
| error | `LOG_ERR` | `daemon.err` |
| warn | `LOG_WARNING` | `daemon.warn` |
| info | `LOG_INFO` | `daemon.info` |

In the tables below, `<CODE> (<detail>)` is an [error code](error-codes.md) with its detail. When a failure has no text detail, only the code appears.

---

## Startup and exit

| Level | Message | Meaning |
| :--- | :--- | :--- |
| error | `invalid configuration: <CODE> (<detail>)` | `/etc/config/wgpathd` failed validation. The daemon exits with status 1. Under the init script this is normally caught before the daemon starts; see [Init script](#init-script). See [UCI configuration](uci-config.md#validation-order). |
| error | `startup failed: <CODE> (<detail>)` | The interface was not in `wireguard status`, the ubus object could not be published, or the hub listener could not bind. The daemon exits with status 1, and procd starts it again after 5 seconds. |
| warn | `unknown mode '<mode>', running in observe mode` | The spoke's `mode` is neither `steer` nor `observe`. Logged at startup and on every reload. |
| info | `started as <role>` | Startup completed; the first cycle follows. `<role>` is `spoke` or `hub`. |

The two error messages are also written to standard error, prefixed with `wgpathd: `. Under procd, standard error is forwarded to the system log, so each appears twice in `logread`.

Typical startup failures:

```
invalid configuration: CONFIG_INVALID_ROLE (unset)
invalid configuration: CONFIG_MISSING_OPTION (discovery)
invalid configuration: INTERFACE_MISSING (wg_mesh)
invalid configuration: CONFIG_INVALID_OPTION (n_up)
startup failed: INTERFACE_MISSING (wg_mesh: WG_PARSE_FAILED (no interface wg_mesh))
startup failed: PUBLISHER_LISTEN_FAILED (10.10.0.1:7780: bind(): Address not available)
```

`invalid configuration: INTERFACE_MISSING` means no UCI `interface` section has that name. `startup failed: INTERFACE_MISSING` means the UCI section exists but the kernel interface is not in the `wireguard status` reply, typically because it is down.

## Init script

`service wgpathd start` and `service wgpathd reload` run the config check first. When it fails, the init script logs through `logger` with the tag `wgpathd` (no PID) at `daemon.err`: each line of the check report, then one of:

| Level | Message | Meaning |
| :--- | :--- | :--- |
| error | `FAIL  config: <reason>` | The failed check. The reasons are listed in [Service commands](service-commands.md#findings). |
| error | `invalid configuration, not starting` | `start` created no instance. |
| error | `invalid configuration, keeping the running one` | `reload` did not signal the daemon; it keeps its configuration. |

The same lines go to standard error of the `service` command.

## Reload

| Level | Message | Meaning |
| :--- | :--- | :--- |
| info | `configuration reloaded (peers: <n> kept, <n> added, <n> removed)` | A spoke applied a reload. Kept peers had the same key, relay and tunnel address; changed peers count as removed and added. |
| info | `configuration reloaded` | A hub applied a reload. The hub has no option that applies live, so nothing changes. |
| info | `reload: <option> changed, exiting for procd to start afresh` | The reload changes an option that needs a new process. The daemon exits with status 0 and procd starts it again after 5 seconds. |
| error | `reload: invalid configuration, keeping the running one: <CODE> (<detail>)` | The configuration read on `SIGHUP` is invalid. Nothing changes. |

What a reload applies is listed in [Service commands](service-commands.md#reload).

## Unmanaged peers (spoke)

| Level | Message | Meaning |
| :--- | :--- | :--- |
| info | `peer section <section> unmanaged: <reason>` | A mesh peer will not be steered. Logged once per peer at startup, when a reload adds or changes the peer, and when a waiting peer's relay route later resolves into `mesh_iface`. Reasons are listed in [Substrate annotations](substrate.md#managed-and-unmanaged-peers). |
| info | `peer <pubkey>: relay route found, now managed` | A peer whose relay route lookup had failed now has a route outside `mesh_iface` and is steered from now on. |

## Path changes (spoke)

| Level | Message | Meaning |
| :--- | :--- | :--- |
| info | `peer <pubkey>: transition <from> -> <to> (<reason>)` | A state transition. Reasons: `trial_start`, `trial_ok`, `trial_timeout`, `demoted`. |
| info | `peer <pubkey>: roam DIRECT -> DIRECT (roam_adopted)` | In DIRECT, the peer's kernel endpoint moved to a new direct address, which is now the target. |

## Cycle problems

| Level | Message | Role | Meaning |
| :--- | :--- | :--- | :--- |
| warn | `reading <iface> failed: <CODE> (<detail>)` | both | `ubus call wireguard status` failed or did not contain the interface. Logged once when failures start. A spoke decides nothing while this lasts; a hub keeps its last snapshot. |
| info | `reading <iface> recovered` | both | The first successful read after a failure. |
| warn | `peer <pubkey>: absent from <mesh_iface>, skipped` | spoke | A managed peer is not in the kernel's peer table. Logged once each time it disappears; the peer is skipped until it returns. |
| warn | `peer <pubkey>: setting endpoint failed: WG_COMMAND_FAILED (<detail>)` | spoke | `wg set` failed. The detail is `exit <code>`, or `EXEC_TIMEOUT (wg)` if it took more than 2 seconds. Logged once when failures start for that peer. No tunnel probe is sent for that peer while it fails. |
| info | `peer <pubkey>: setting endpoint recovered` | spoke | The first successful `wg set` for that peer after a failure. |
| warn | `discovery failed: <CODE> (<detail>)` | spoke | A discovery fetch failed. Logged once when failures start. See [Discovery HTTP API](discovery-api.md#spoke-side-validation). |
| info | `discovery recovered` | spoke | The first successful fetch after a failure. |
| warn | `cannot save the discovery cache to /var/run/wgpathd/cache.json` | spoke | A valid payload was received but the cache file could not be written. The payload is still used. |
| warn | `watchdog ping failed: <CODE> (<detail>)` | both | The `ubus call service watchdog` at the end of a cycle failed. Logged once when failures start. |
| info | `watchdog ping recovered` | both | The first successful watchdog ping after a failure. |

Each `... failed:` line in this table marks the start of an outage and is not repeated while the outage lasts, even if the code or detail changes. The matching `... recovered` line marks its end.

`watchdog ping failed` without a recovery usually means procd does not know the service `wgpathd`, for example when the daemon was started by hand or in a container without procd.
