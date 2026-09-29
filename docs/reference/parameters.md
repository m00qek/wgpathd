# Timing Parameters

Each parameter can be overridden by an option of the same name in the `main` section of `/etc/config/wgpathd`, for example `option n_up '3'`. Values are in seconds unless noted. For the accepted number format, see [UCI configuration](uci-config.md#timing-parameters). A running daemon picks up changed values on `service wgpathd reload`, from its next cycle.

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

The hub uses only `cycle`, as the interval between snapshots of `read_iface`. It accepts and validates the other parameters but does not use them.

## Behavior details

**`cycle`.** The next cycle is scheduled `cycle` seconds after the current one completes. A spoke cycle completes when the `wireguard status` read, the underlay probes, the one `wg set` command, the tunnel probes and the endpoint reads that follow their answers have returned or timed out. The effective period is therefore `cycle` plus the time those take.

**`n_up`.** Evidence is counted only in RELAY. A cycle without evidence resets the count to zero. Every state change resets it. Counting continues during a backoff. A cycle in RELAY that sees an authenticated roam (the kernel endpoint moved to a direct address wgpathd did not set) is enough on its own: the trial toward the roamed address starts on that cycle, or on the first cycle after the backoff that still sees one.

**`m_down`.** In DIRECT, a tunnel probe that was not answered, timed out, or was not sent (for example because `wg set` failed) counts as failed. The probe fills the MTU of `mesh_iface`, so a path that loses full-size packets fails it even when small ones get through. Any answer resets the count, whichever path the kernel endpoint shows right after it. A trial is stricter: right after an answer, wgpathd reads the kernel endpoint, which the answer itself moved, and only an answer that came back from the trial's target commits it.

**`tunnel_timeout`.** wgpathd sends the probes itself, as ICMP echo requests, and waits exactly `tunnel_timeout` seconds for each reply, fractions included: `0.5` waits half a second. A reply that arrives later is ignored, even in a later cycle. The probes of one cycle go out together and wait together, so a cycle waits at most `tunnel_timeout` for the underlay probes of the peers in RELAY, and at most `tunnel_timeout` again, after `wg set`, for the tunnel probes of the peers trialing or in DIRECT.

**`trial_window`.** Measured from the cycle in which the trial started. The deadline is checked before the probe result: an answer that is read at or after the deadline is a timeout. The tunnel probe answer is read one cycle after it is sent. A good path answers the first probe and commits one cycle after the trial starts. A second probe is read two cycles after the start; while the path fails, each of those cycles lasts `cycle` plus about `tunnel_timeout`, so with the defaults the second answer arrives after the 8-second deadline and the trial times out on its first probe.

**Backoff.** A failed trial or a demotion sets the backoff to `backoff_min` if it was zero, otherwise to twice its value, capped at `backoff_max`. No trial starts until that many seconds have passed since the failure. While in DIRECT, once the peer has held DIRECT for `backoff_reset`, the backoff returns to zero. A demotion caused by switching to observe mode does not change the backoff.

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
| Discovery server: maximum open connections | 16 |
| procd watchdog timeout (init script) | 30 s |
| procd respawn delay (init script) | 5 s |

For how these parameters shape behavior, see [About the path state machine](../explanation/state-machine.md). To change them, see [How to tune timing parameters](../how-to/tune-timing.md).
