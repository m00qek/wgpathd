# How to Tune Timing Parameters

The defaults suit a few sites on ordinary broadband: leave a dead direct path in roughly 8 to 15 seconds, and return to direct after about 15 to 20 seconds of evidence plus a trial. Change them only when you have a reason, such as a lab where you want faster transitions, or a path that flaps.

---

## Set a parameter

Each parameter is an option in the `main` section of `/etc/config/wgpathd`. For example, to require 10 cycles of evidence instead of 5:

```bash
uci set wgpathd.main.n_up='10'
uci commit wgpathd
service wgpathd reload
```

The running daemon applies the new value from its next cycle, and peers keep their state.

To go back to the default, delete the option:

```bash
uci delete wgpathd.main.n_up
uci commit wgpathd
service wgpathd reload
```

Each parameter has bounds, and a spoke's parameters must agree with each other (see below). A value outside them is refused: the reload prints a line such as `FAIL  config: option cycle must be a number from 1 to 10` and the daemon keeps its current values. `service wgpathd check` shows the same line before you reload. All names, defaults and exact semantics are in [Timing parameters](../reference/parameters.md).

## Common adjustments

**Fall back faster or slower.** A cycle lasts `cycle` plus the time its probes wait, and on a dead path the tunnel probe waits for its timeout: with the defaults a cycle then takes about 4 seconds. A dead path is left after `m_down` to `m_down + 1` such cycles. Lower `m_down` to `1` to fall back on the first missed probe; raise it if a lossy link causes needless fallbacks.

**Return to direct more cautiously.** Raise `n_up` to demand a longer run of evidence, and raise `backoff_min` so a failed trial or a fallback waits longer before the next attempt.

**Park a flapping path sooner or longer.** The backoff doubles from `backoff_min` up to `backoff_max` with each failure, and only resets after `backoff_reset` seconds of stable DIRECT. Raise `backoff_max` to hold a bad path on the relay longer; lower `backoff_reset` to forgive a path sooner.

**Pick up roaming peers faster.** Lower `discovery_interval`. Peers stuck in RELAY without evidence already trigger a refresh at most every 10 seconds, so this mostly helps peers that are DIRECT or have evidence.

**Speed everything up for a lab.** For example:

```
config wgpathd 'main'
	...
	option cycle 1
	option n_up 3
	option trial_window 3
	option backoff_min 5
	option backoff_max 20
	option backoff_reset 30
	option discovery_interval 10
```

## Keep these relationships

On a spoke, wgpathd refuses two combinations, whichever of the values you set:

- `trial_window` must be longer than `cycle` plus `tunnel_timeout`, or even a good path would fail its trial. So raising `cycle` or `tunnel_timeout` may mean raising `trial_window` too: `cycle 8` needs a `trial_window` above 9. The tunnel probe answer is read one cycle after it is sent, and the deadline is checked first. A second attempt fits only if two cycles, including their probe waits, end before the deadline. With the defaults they usually do not, so a trial normally stands or falls on its first probe.
- `backoff_max` must be at least `backoff_min`. Raising `backoff_min` above 900 therefore means raising `backoff_max` with it.

Keep the others in mind yourself:

- `tunnel_timeout` must exceed the round-trip time of the slowest direct path, or answers arrive too late and count as lost. Fractions work: `0.5` waits half a second. Raise it only for a path whose replies are slow: a cycle waits for its probes, so while a path is dead each cycle takes up to `tunnel_timeout` longer, or twice that when some peers are in RELAY (their underlay probes) and others trialing or DIRECT (their tunnel probes).
- procd restarts the daemon if 30 seconds pass without a watchdog ping, and the daemon pings once per cycle. The upper bounds of `cycle` (10) and `tunnel_timeout` (5) keep the longest cycle within that; see [Timing parameters](../reference/parameters.md#bounds).

The hub uses only `cycle`, as its snapshot interval.
