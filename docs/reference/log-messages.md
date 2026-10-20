# Log Messages

wgpathd logs to syslog with the identifier `wgpathd`, its PID, and facility `daemon`.

```bash
logread -e wgpathd
```

A line looks like this:

```
Sun Sep 27 10:15:03 2026 daemon.notice wgpathd[2481]: peer spoke_b (SpokeBme): transition RELAY -> TRIALING reason=trial_start endpoint=[2001:db8:b::20]:51820
```

When the daemon runs in the foreground with standard error on a terminal, or with `WGPATHD_STDERR=1` in its environment, each message is also written to standard error, prefixed by its level, as in `notice: started role=hub`. Under procd standard error is not a terminal, so nothing is logged twice.

An uncaught exception is not a wgpathd message: procd forwards the daemon's standard error to syslog under the identifier `daemon.uc[<PID>]`, so `logread -e wgpathd` does not show it. Use `logread -e daemon.uc` to find one.

---

## Levels

| Level | syslog priority | Shown by `logread` as | Used for |
| :--- | :--- | :--- | :--- |
| err | `LOG_ERR` | `daemon.err` | The daemon cannot run, or refuses a new configuration. |
| warning | `LOG_WARNING` | `daemon.warn` | A problem that needs attention: an outage, or a peer left unmanaged by a configuration error. |
| notice | `LOG_NOTICE` | `daemon.notice` | An event an operator wants to see: a path change, a recovery, start, stop and reload. |
| info | `LOG_INFO` | `daemon.info` | Routine detail. |

wgpathd logs nothing at `debug`.

## Message grammar

The format of every message is stable, so it can be matched by scripts:

```
[<subject>: ]<event>[ key=value ...]
```

- A line about a peer has the subject `peer <section> (<key prefix>)`: the peer's UCI section in `/etc/config/network` and the first 8 characters of its public key. A peer with no valid public key has the subject `peer <section>`.
- Keys and values contain no spaces, except the value of the last key, which runs to the end of the line (such as `reason=relay routes into wg_mesh`).
- An outage is reported as a pair: `[<subject>: ]<what> failed: <CODE> (<detail>)` when it starts, and `[<subject>: ]<what> recovered` when it ends. The `failed` line is not repeated while the outage lasts, even if the code or detail changes.

In the tables below, `<CODE> (<detail>)` is an [error code](error-codes.md) with its detail. When a failure has no text detail, only the code appears. `<peer>` stands for the peer subject.

## Startup and exit

| Level | Message | Meaning |
| :--- | :--- | :--- |
| err | `invalid configuration: <CODE> (<detail>)` | `/etc/config/wgpathd` failed validation. The daemon exits with status 1. Under the init script this is normally caught before the daemon starts; see [Init script](#init-script). See [UCI configuration](uci-config.md#validation-order). |
| err | `startup failed: <CODE> (<detail>)` | The interface was not in `wireguard status`, the ubus object could not be published, or the hub listener could not bind. The daemon exits with status 1, and procd starts it again after 5 seconds. |
| warning | `network section <section>: ignoring <options>, left over from an earlier version; run service wgpathd migrate` | The section of `/etc/config/network` still has `wgpathd_relay`, `wgpathd_tunnel` or both (`<options>`, joined by `and`), which this release does not read. Logged once per section at startup, in both roles, not on reload. See [How to upgrade from a release that kept peer settings in the network configuration](../how-to/upgrade-peer-settings.md). |
| warning | `unknown mode, running in observe mode value=<mode>` | The spoke's `mode` is neither `steer` nor `observe`. Logged at startup and on every reload. |
| info | `discovery cache: loaded peers=<n>` | A spoke started with `<n>` peers from the discovery cache in `/var/run/wgpathd/cache.json`. |
| info | `discovery cache: none usable` | A spoke started without a discovery cache, or with one that failed validation. |
| notice | `started role=spoke mode=<mode> managed=<n> unmanaged=<n>` | A spoke completed startup; the first cycle follows. `unmanaged` counts peers waiting on a relay route too. |
| notice | `started role=hub` | A hub completed startup. |
| notice | `stopped` | The daemon left its loop and exits with status 0: procd stopped it (`service wgpathd stop` or `restart`), or a reload needs a new process. |
| notice | `stopped code=<n>` | The daemon left its loop and exits with status `<n>`, as after `startup failed:`. |

Typical startup failures:

```
invalid configuration: CONFIG_INVALID_ROLE (unset)
invalid configuration: CONFIG_MISSING_OPTION (discovery)
invalid configuration: INTERFACE_MISSING (wg_mesh)
invalid configuration: CONFIG_INVALID_OPTION (n_up must be a whole number from 1 to 100)
startup failed: INTERFACE_MISSING (wg_mesh: WG_PARSE_FAILED (no interface wg_mesh))
startup failed: PUBLISHER_LISTEN_FAILED (10.10.0.1:7780: bind(): Address not available)
```

`invalid configuration: INTERFACE_MISSING` means no UCI `interface` section has that name. `startup failed: INTERFACE_MISSING` means the UCI section exists but the kernel interface is not in the `wireguard status` reply, typically because it is down.

## Init script

`service wgpathd start` and `service wgpathd reload` run the config check first. When it fails, the init script logs through `logger` with the tag `wgpathd` (no PID) at `daemon.err`: each line of the check report, then one of:

| Level | Message | Meaning |
| :--- | :--- | :--- |
| err | `FAIL  config: <reason>` | The failed check. The reasons are listed in [Service commands](service-commands.md#findings). |
| err | `invalid configuration, not starting` | `start` created no instance. |
| err | `invalid configuration, keeping the running one` | `reload` did not signal the daemon; it keeps its configuration. |

The same lines go to standard error of the `service` command.

## Reload

| Level | Message | Meaning |
| :--- | :--- | :--- |
| notice | `configuration reloaded peers_kept=<n> added=<n> removed=<n>` | A spoke applied a reload. Kept peers had the same key, relay and tunnel address; a changed peer counts as removed and added. ` mode=<mode>` is appended when the mode changed. |
| notice | `configuration reloaded` | A hub applied a reload. Only `cycle` applies live on a hub; its other options need a new process. |
| info | `<peer>: added` | A reload added this managed peer. It starts in RELAY. |
| info | `<peer>: changed` | A reload changed this peer's relay or tunnel address. It starts again in RELAY. |
| info | `<peer>: removed` | A reload removed this peer from steering. |
| notice | `reload: exiting for procd to start afresh changed=<option>` | The reload changes an option that needs a new process. The daemon exits with status 0 and procd starts it again after 5 seconds. |
| err | `reload: invalid configuration, keeping the running one: <CODE> (<detail>)` | The configuration read on `SIGHUP` is invalid. Nothing changes. |

What a reload applies is listed in [Service commands](service-commands.md#reload).

## Unmanaged peers (spoke)

| Level | Message | Meaning |
| :--- | :--- | :--- |
| warning | `<peer>: unmanaged reason=<reason>` | A mesh peer will not be steered: `invalid public_key`, `not configured`, `fixed endpoint`, `configured more than once`, `missing relay`, `invalid relay`, `missing tunnel`, `invalid tunnel`, or `relay routes into <mesh_iface>`. Logged once per peer at startup, when a reload adds or changes the peer, and when a waiting peer's relay route later resolves into `mesh_iface`. The hub peer, which has a fixed endpoint and no `peer` section, is logged with `fixed endpoint`. See [Managed and unmanaged peers](uci-config.md#managed-and-unmanaged-peers). |
| info | `<peer>: unmanaged reason=relay route lookup failed: <CODE> (<detail>)` | The route lookup for the peer's relay host failed, typically because `wg_hub` is not up yet. It is retried every cycle. |
| notice | `<peer>: relay route found, now managed` | A peer whose relay route lookup had failed, or that a reload guarded again, now has a route outside `mesh_iface` and is steered from now on. |

## Path changes (spoke)

| Level | Message | Meaning |
| :--- | :--- | :--- |
| notice | `<peer>: transition <from> -> <to> reason=<reason>[ failed_probes=<n>][ backoff=<s>s] endpoint=<endpoint>` | A state transition. `endpoint` is the endpoint wgpathd sets for the new state. `demoted` adds `failed_probes` (the `m_down` probes in a row that were lost or answered over the relay) and `backoff`; `trial_timeout` adds `backoff`. The reasons are listed below. |
| notice | `<peer>: roamed endpoint=<endpoint>` | In DIRECT, the peer's kernel endpoint moved to a new direct address, which is now the target. |
| notice | `<peer>: ready, steer would trial endpoint=<endpoint>` | Observe mode only: the peer has earned `n_up` cycles of direct evidence, or saw an authenticated roam this cycle. `endpoint` is the endpoint a trial would take: the roam's source if one was seen, else the discovered endpoint. In steer mode it would start a trial now. Logged once, until `no longer ready`. |
| info | `<peer>: no longer ready` | Observe mode only: the peer is not ready and has had no direct evidence for more than `n_up` cycles in a row. A roam makes a peer ready for its cycle alone, so the line waits out the cycles between roams instead of following each one. |
| warning | `<peer>: candidate refused endpoint=<endpoint> reason=<reason>` | The peer's candidate from discovery is not taken, for one of the reasons in [Discovery HTTP API](discovery-api.md#spoke-side-validation): `own address`, `relay address`, `tunnel address` or `routes into <iface>`. Logged when the refusal starts or its reason changes. Meanwhile the candidate is neither probed nor trialed. |
| notice | `<peer>: candidate no longer refused` | The refused candidate is taken again, or discovery no longer offers it. |
| notice | `<peer>: direct address given up endpoint=<endpoint> failed_trials=<n> pause=<s>s` | Steer mode only: the trial toward `endpoint` timed out, the `n`-th in a row on that address, which reaches `give_up_after`. The underlay echo alone starts no trial toward it for `pause` (`give_up_pause`). Logged right after the `trial_timeout` transition. `n` is above `give_up_after` when the one trial after a pause or a roam failed as well. See [Giving up an address](../explanation/state-machine.md#giving-up-an-address). |
| notice | `<peer>: direct address trials resumed reason=<reason> endpoint=<endpoint>` | Steer mode only: a trial starts although `endpoint`, the address given up, still was. Logged right before its `trial_start` transition. The reasons are listed below. |

| Reason | Transition |
| :--- | :--- |
| `trial_start` | RELAY → TRIALING |
| `trial_ok` | TRIALING → DIRECT, on a tunnel probe answered from the trial's target |
| `trial_timeout` | TRIALING → RELAY, no answer over the direct path within `trial_window` |
| `demoted` | DIRECT → RELAY after `m_down` failed probes |
| `observe_mode` | TRIALING or DIRECT → RELAY because the mode is not `steer` |

The reasons of `direct address trials resumed`:

| Reason | Why trials resumed |
| :--- | :--- |
| `roam` | An authenticated roam: the peer's packets arrived directly. The trial takes the roam's source as its target. |
| `new_candidate` | Discovery offers another address for the peer, and it answers the underlay echo. The trial takes that address. |
| `pause_over` | `give_up_pause` has passed since the address was given up. The trial takes the given-up address once more. |

For example:

```
peer spoke_b (SpokeBme): transition RELAY -> TRIALING reason=trial_start endpoint=[2001:db8:b::20]:51820
peer spoke_b (SpokeBme): transition TRIALING -> DIRECT reason=trial_ok endpoint=[2001:db8:b::20]:51820
peer spoke_b (SpokeBme): roamed endpoint=[2001:db8:b::21]:51820
peer spoke_b (SpokeBme): transition DIRECT -> RELAY reason=demoted failed_probes=2 backoff=60s endpoint=10.10.0.12:51820
```

An address that answers ping but not WireGuard, given up at the third timeout and tried once more when the pause is over:

```
peer spoke_c (SpokeCme): transition TRIALING -> RELAY reason=trial_timeout backoff=120s endpoint=10.10.0.13:51820
peer spoke_c (SpokeCme): direct address given up endpoint=[2001:db8:c::30]:51820 failed_trials=3 pause=21600s
peer spoke_c (SpokeCme): direct address trials resumed reason=pause_over endpoint=[2001:db8:c::30]:51820
peer spoke_c (SpokeCme): transition RELAY -> TRIALING reason=trial_start endpoint=[2001:db8:c::30]:51820
peer spoke_c (SpokeCme): transition TRIALING -> RELAY reason=trial_timeout backoff=240s endpoint=10.10.0.13:51820
peer spoke_c (SpokeCme): direct address given up endpoint=[2001:db8:c::30]:51820 failed_trials=4 pause=21600s
```

## Cycle problems

| Level | Message | Role | Meaning |
| :--- | :--- | :--- | :--- |
| warning | `reading <iface> failed: <CODE> (<detail>)` | both | `ubus call wireguard status` failed or did not contain the interface. A spoke decides nothing while this lasts; a hub keeps its last snapshot. |
| notice | `reading <iface> recovered` | both | The first successful read after a failure. |
| notice | `<mesh_iface> was created again: its endpoints are asserted again, none is taken as a roam` | spoke | The interface has a new index between two reads, as when netifd recreates it on `ifup` or a network reload. It starts on the endpoints of its configuration, which no packet has proven, so this cycle sets every peer's endpoint again and treats none as a [roam](../explanation/state-machine.md#why-the-anchor-needs-roams). |
| notice | `<mesh_iface> may have been created again: its endpoints are asserted again, none is taken as a roam` | spoke | The first good read after reads failed. The interface may have been recreated while it could not be read, so this cycle is treated the same way. |
| warning | `<peer>: absent from <mesh_iface>, skipped` | spoke | A managed peer is not in the kernel's peer table. Logged once each time it disappears; the peer is skipped until it returns. |
| notice | `<peer>: back in <mesh_iface>` | spoke | The absent peer is in the kernel's peer table again and is steered from this cycle. |
| warning | `setting endpoints on <mesh_iface> failed: WG_COMMAND_FAILED (<detail>)` | spoke | The cycle's `wg set`, which sets every peer's endpoint in one command, failed. The detail is `exit <code>`, or `EXEC_TIMEOUT (wg)` if it took more than 2 seconds. No tunnel probe is sent while it fails. |
| notice | `setting endpoints on <mesh_iface> recovered` | spoke | The first successful `wg set` after a failure. |
| warning | `reading the MTU of <mesh_iface> failed: LINK_LOOKUP_FAILED (<detail>)` | spoke | The MTU that sizes the tunnel probes could not be read. No tunnel probe is sent while it fails. |
| notice | `reading the MTU of <mesh_iface> recovered` | spoke | The first successful MTU read after a failure. |
| warning | `sending probes failed: PROBE_SEND_FAILED (<detail>)` | spoke | At least one probe of a cycle could not be sent; the detail is the first such failure. The probe counts as unanswered. |
| notice | `sending probes recovered` | spoke | The first cycle whose probes could all be sent, after a failure. |
| warning | `discovery failed: <CODE> (<detail>)` | spoke | A discovery fetch failed. See [Discovery HTTP API](discovery-api.md#spoke-side-validation). |
| notice | `discovery recovered` | spoke | The first successful fetch after a failure. |
| warning | `saving the discovery cache failed: CACHE_SAVE_FAILED (/var/run/wgpathd/cache.json: <cause>)` | spoke | A valid payload was received but the cache file could not be written; the causes are listed in [Error codes](error-codes.md#discovery). The payload is still used. |
| notice | `saving the discovery cache recovered` | spoke | The first successful cache write after a failure. |
| warning | `watchdog ping failed: <CODE> (<detail>)` | both | The `ubus call service watchdog` at the end of a cycle failed. |
| notice | `watchdog ping recovered` | both | The first successful watchdog ping after a failure. |

Each `failed:` line in this table marks the start of an outage; the matching `recovered` line marks its end.

`watchdog ping failed` without a recovery usually means procd does not know the service `wgpathd`, for example when the daemon was started by hand or in a container without procd.

A URL in a message shows the scheme, host, port and path only: never the `user:password@` part, the query or the fragment. A value that does not read as `scheme://host[:port]` shows as `(unreadable url)`.

## Migration

`/usr/libexec/wgpathd/migrate.uc`, run by the uci-defaults script `/etc/uci-defaults/50-wgpathd-peers` after an install or upgrade and by `service wgpathd migrate`, logs through the same syslog identifier, `wgpathd`, each message starting with `migrate:`. It logs nothing when there is nothing to move.

```bash
logread -e 'migrate:'
```

| Level | Message | Meaning |
| :--- | :--- | :--- |
| notice | `migrate: moved the settings of <n> peer(s) from /etc/config/network to /etc/config/wgpathd` | Both files are committed: the `peer` sections hold the settings, and the options are gone from network. |
| warning | `migrate: network section <section>: kept <option> '<value>' of /etc/config/wgpathd, dropped <legacy option> '<value>'` | The peer's `peer` section already had a different `relay` or `tunnel`. That value is kept; the one from network is removed with the rest. |
| warning | `migrate: network section <section> has no valid public_key, its options stay` | The section cannot be keyed, so its options are not moved. `service wgpathd check` keeps warning about them. |
| err | `migrate: failed, /etc/config/network left as it was: MIGRATE_FAILED (<detail>)` | A step failed; the details are listed in [Error codes](error-codes.md#migration). Settings already committed to `/etc/config/wgpathd` stay, and a later run finishes the job. Run from the uci-defaults script, it runs again at the next boot. |
