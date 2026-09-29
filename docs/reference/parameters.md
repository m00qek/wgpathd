# Timing Parameters

Each parameter can be overridden by an option of the same name in the `main` section of `/etc/config/wgpathd`, for example `option n_up '3'`. Values are in seconds unless noted. Each has bounds, described [below](#bounds). A running daemon picks up changed values on `service wgpathd reload`, from its next cycle.

---

| Parameter | Default | Unit | Used by | Meaning |
| :--- | :--- | :--- | :--- | :--- |
| `cycle` | `3` | s | spoke, hub | Pause between the end of one cycle and the start of the next. |
| `n_up` | `5` | cycles | spoke | Consecutive cycles with direct evidence needed before a trial may start. An authenticated roam needs no streak. |
| `m_down` | `2` | cycles | spoke | Consecutive failed tunnel probes in DIRECT that demote a peer to RELAY. A probe answered over the relay counts as failed. |
| `tunnel_timeout` | `1` | s | spoke | How long the underlay probes and the tunnel probes wait for replies. |
| `trial_window` | `8` | s | spoke | How long a trial may wait for a tunnel probe answer before it fails. |
| `backoff_min` | `30` | s | spoke | Backoff after the first failed trial or demotion. |
| `backoff_max` | `900` | s | spoke | Upper limit of the backoff. |
| `backoff_reset` | `600` | s | spoke | Time a peer must stay in DIRECT before its backoff returns to zero. |
| `discovery_interval` | `60` | s | spoke | Interval between regular discovery fetches. |
| `give_up_after` | `3` | trials | spoke | Failed trials in a row on the same address after which the address is given up: the underlay echo alone no longer starts a trial toward it. |
| `give_up_pause` | `21600` | s | spoke | How long an address stays given up before the echo may start one more trial toward it. |

The hub uses only `cycle`, as the interval between snapshots of `read_iface`. It accepts and validates the other parameters but does not use them.

## Bounds

A value must be a decimal number within its bounds, both included; `n_up`, `m_down` and `give_up_after` must be whole numbers. A value outside them stops startup, fails `service wgpathd check`, and is refused on reload, which keeps the running values; the error is `CONFIG_INVALID_OPTION` with the detail `<name> must be a number from <min> to <max>`, or `a whole number` for the counts.

| Parameter | Minimum | Maximum | Why |
| :--- | :--- | :--- | :--- |
| `cycle` | `1` | `10` | Every spoke cycle runs `wg set` and reads `wireguard status`: a shorter pause mostly starts processes. The maximum keeps the watchdog fed, see below. |
| `n_up` | `1` | `100` | A count of cycles. |
| `m_down` | `1` | `100` | A count of cycles. |
| `tunnel_timeout` | `0.1` | `5` | Shorter than any real round trip it is meant to wait for, the probes would all count as lost. The maximum keeps the watchdog fed. |
| `trial_window` | `1` | `60` | A trial sends the peer's traffic over an unproven path, so a failing one should not last longer than a minute. |
| `backoff_min`, `backoff_max`, `backoff_reset` | `1` | `86400` | Up to a day. |
| `discovery_interval` | `5` | `86400` | Every spoke fetches from the hub at this interval. |
| `give_up_after` | `1` | `100` | A count of trials. |
| `give_up_pause` | `60` | `604800` | From a minute to a week. |

procd restarts the daemon when 30 seconds pass without a watchdog ping, and the daemon pings once per cycle, when the cycle completes. Between two pings a spoke waits `cycle`, up to `tunnel_timeout` for the underlay probes, up to 2 s for `wg set`, and up to `tunnel_timeout` for the tunnel probes: at the maxima 10 + 5 + 2 + 5 = 22 seconds, which leaves 8 for the `wireguard status` reads.

On a spoke, two combinations are refused as well, with the effective values, defaults included:

| Rule | Detail |
| :--- | :--- |
| `backoff_max` ≥ `backoff_min` | `backoff_max must be at least backoff_min (<value>)` |
| `trial_window` > `cycle` + `tunnel_timeout` | `trial_window must be longer than cycle + tunnel_timeout (<sum>)` |

The first answer to a trial's probe is read a cycle, and a probe wait, after the trial starts, so a shorter window fails every trial. A hub is held to the bounds alone.

## Behavior details

**`cycle`.** The next cycle is scheduled `cycle` seconds after the current one completes. A spoke cycle completes when the `wireguard status` read, the underlay probes, the one `wg set` command, the tunnel probes and the endpoint reads that follow their answers have returned or timed out. The effective period is therefore `cycle` plus the time those take.

**`n_up`.** Evidence is counted only in RELAY. A cycle without evidence resets the count to zero. Every state change resets it. Counting continues during a backoff. A cycle in RELAY that sees an authenticated roam (the kernel endpoint moved to a direct address wgpathd did not set) is enough on its own: the trial toward the roamed address starts on that cycle, or on the first cycle after the backoff that still sees one.

**`m_down`.** In DIRECT, a tunnel probe that was not answered, timed out, or was not sent (for example because `wg set` failed) counts as failed. The probe fills the MTU of `mesh_iface`, so a path that loses full-size packets fails it even when small ones get through. Any answer resets the count, whichever path the kernel endpoint shows right after it. A trial is stricter: right after an answer, wgpathd reads the kernel endpoint, which the answer itself moved, and only an answer that came back from the trial's target commits it.

**`tunnel_timeout`.** wgpathd sends the probes itself, as ICMP echo requests, and waits exactly `tunnel_timeout` seconds for each reply, fractions included: `0.5` waits half a second. A reply that arrives later is ignored, even in a later cycle. The probes of one cycle go out together and wait together, so a cycle waits at most `tunnel_timeout` for the underlay probes of the peers in RELAY, and at most `tunnel_timeout` again, after `wg set`, for the tunnel probes of the peers trialing or in DIRECT.

**`trial_window`.** Measured from the cycle in which the trial started. The deadline is checked before the probe result: an answer that is read at or after the deadline is a timeout. The tunnel probe answer is read one cycle after it is sent. A good path answers the first probe and commits one cycle after the trial starts. A second probe is read two cycles after the start; while the path fails, each of those cycles lasts `cycle` plus about `tunnel_timeout`, so with the defaults the second answer arrives after the 8-second deadline and the trial times out on its first probe.

**Backoff.** A failed trial or a demotion sets the backoff to `backoff_min` if it was zero, otherwise to twice its value, capped at `backoff_max`. No trial starts until that many seconds have passed since the failure. While in DIRECT, once the peer has held DIRECT for `backoff_reset`, the backoff returns to zero. A demotion caused by switching to observe mode does not change the backoff.

**`give_up_after`.** Only a trial that times out counts, against its target: the endpoint, port included. A timeout on another target starts the count again at one, and a trial that commits clears it; a demotion from DIRECT does not count. At `give_up_after` timeouts in a row the address is given up, and the underlay echo alone starts no trial toward it. An authenticated roam still starts a trial at once, and so does echo evidence for another address from discovery. If the trial that follows is toward the same address and fails, the address is given up again at once. See [Giving up an address](../explanation/state-machine.md#giving-up-an-address).

**`give_up_pause`.** Measured from the timeout that gave the address up. Once it has passed, the echo may start one more trial toward the address, once the backoff has run out too. A reload applies a new value to an address already given up: the pause is measured from the same moment.

**`discovery_interval`.** The first fetch happens on the first cycle. After that a fetch starts when `discovery_interval` has passed since the last one started, or when a peer in RELAY without evidence asks for a refresh and at least 10 seconds have passed. Only one fetch runs at a time.

## Fixed values

These are not configurable.

| Value | Setting |
| :--- | :--- |
| `wg set` time limit | 2 s |
| Underlay probe: ICMPv6 echo payload | 16 bytes |
| Probe nonce, the first bytes of every echo payload | 8 random bytes |
| Tunnel probe: whole IP packet | the MTU of `mesh_iface`, read every cycle; never fragmented |
| Discovery fetch time limit | 5 s |
| Discovery response size limit | 65536 bytes |
| Minimum gap between refresh-driven fetches | 10 s |
| Discovery server: request read time limit | 2 s |
| Discovery server: maximum request size | 4096 bytes |
| Discovery server: maximum open connections | 16, of which at most 2 from one source address |
| procd watchdog timeout (init script) | 30 s |
| procd respawn delay (init script) | 5 s |

For how these parameters shape behavior, see [About the path state machine](../explanation/state-machine.md). To change them, see [How to tune timing parameters](../how-to/tune-timing.md).
