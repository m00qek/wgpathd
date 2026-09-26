# Timing Parameters

Each parameter can be overridden by an option of the same name in the `main` section of `/etc/config/wgpathd`, for example `option n_up '3'`. Values are in seconds unless noted. For the accepted number format, see [UCI configuration](uci-config.md#timing-parameters). A running daemon picks up changed values on `service wgpathd reload`, from its next cycle.

---

| Parameter | Default | Unit | Used by | Meaning |
| :--- | :--- | :--- | :--- | :--- |
| `cycle` | `3` | s | spoke, hub | Pause between the end of one cycle and the start of the next. |
| `n_up` | `5` | cycles | spoke | Consecutive cycles with direct evidence needed before a trial may start. |
| `m_down` | `2` | cycles | spoke | Consecutive failed tunnel probes in DIRECT that demote a peer to RELAY. |
| `tunnel_timeout` | `1` | s | spoke | How long each underlay probe and each tunnel probe waits for a reply. |
| `trial_window` | `8` | s | spoke | How long a trial may wait for a tunnel probe answer before it fails. |
| `backoff_min` | `30` | s | spoke | Backoff after the first failed trial or demotion. |
| `backoff_max` | `900` | s | spoke | Upper limit of the backoff. |
| `backoff_reset` | `600` | s | spoke | Time a peer must stay in DIRECT before its backoff returns to zero. |
| `discovery_interval` | `60` | s | spoke | Interval between regular discovery fetches. |

The hub uses only `cycle`, as the interval between snapshots of `read_iface`. It accepts and validates the other parameters but does not use them.

## Behavior details

**`cycle`.** The next cycle is scheduled `cycle` seconds after the current one completes. A spoke cycle completes when the `wireguard status` read, all underlay probes, all `wg set` commands and all tunnel probes have returned or timed out. The effective period is therefore `cycle` plus the time those take.

**`n_up`.** Evidence is counted only in RELAY. A cycle without evidence resets the count to zero. Every state change resets it. Counting continues during a backoff.

**`m_down`.** In DIRECT, a tunnel probe that was not answered, timed out, or was not sent (for example because `wg set` failed) counts as failed. An answered probe resets the count.

**`tunnel_timeout`.** Both probes run busybox `ping -c1 -W<n>`, where `<n>` is `tunnel_timeout` rounded up to whole seconds, and at least `1`: `0.5` and `1` give `-W1`, `1.5` and `2` give `-W2`. `ping` gives up on its own after `<n>` seconds. wgpathd stops waiting for the command half a second later, `<n> + 0.5` seconds after it started, and counts that as no answer.

**`trial_window`.** Measured from the cycle in which the trial started. The deadline is checked before the probe result: an answer that is read at or after the deadline is a timeout. The tunnel probe answer is read one cycle after it is sent, so with the defaults a trial gets two chances.

**Backoff.** A failed trial or a demotion sets the backoff to `backoff_min` if it was zero, otherwise to twice its value, capped at `backoff_max`. No trial starts until that many seconds have passed since the failure. While in DIRECT, once the peer has held DIRECT for `backoff_reset`, the backoff returns to zero. A demotion caused by switching to observe mode does not change the backoff.

**`discovery_interval`.** The first fetch happens on the first cycle. After that a fetch starts when `discovery_interval` has passed since the last one started, or when a peer in RELAY without evidence asks for a refresh and at least 10 seconds have passed. Only one fetch runs at a time.

## Fixed values

These are not configurable.

| Value | Setting |
| :--- | :--- |
| `wg set` time limit | 2 s |
| Probe command time limit beyond `ping -W` | 0.5 s |
| Discovery fetch time limit | 5 s |
| Discovery response size limit | 65536 bytes |
| Minimum gap between refresh-driven fetches | 10 s |
| Discovery server: request read time limit | 2 s |
| Discovery server: maximum request size | 4096 bytes |
| Discovery server: maximum open connections | 16 |
| procd watchdog timeout (init script) | 30 s |
| procd respawn delay (init script) | 5 s |

For how these parameters shape behavior, see [About the path state machine](../explanation/state-machine.md). To change them, see [How to tune timing parameters](../how-to/tune-timing.md).
