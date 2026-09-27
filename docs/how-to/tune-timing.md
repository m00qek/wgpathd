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

A value that is not a positive decimal number is refused: the reload prints `FAIL  config: option <name> must be a positive number` and the daemon keeps its current values. `service wgpathd check` shows the same line before you reload. All names, defaults and exact semantics are in [Timing parameters](../reference/parameters.md).

## Common adjustments

**Fall back faster or slower.** A cycle lasts `cycle` plus the time its probes wait, and on a dead path the probes wait for their timeout: with the defaults a cycle then takes 4 to 5 seconds. A dead path is left after `m_down` to `m_down + 1` such cycles. Lower `m_down` to `1` to fall back on the first missed probe; raise it if a lossy link causes needless fallbacks.

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

wgpathd does not cross-check parameters, so keep them consistent yourself:

- `trial_window` should be longer than one cycle plus `tunnel_timeout`, or even a good path can fail its trial. The tunnel probe answer is read one cycle after it is sent, and the deadline is checked first. A second attempt fits only if two cycles, including their probe waits, end before the deadline. With the defaults they usually do not, so a trial normally stands or falls on its first probe.
- `tunnel_timeout` is rounded up to whole seconds for `ping`, so `0.5` waits as long as `1`. Raise it only for a path whose replies are slow: a cycle waits for its probes, so while a path is dead each cycle takes up to twice the rounded value plus one second longer (the underlay probe, then the tunnel probe).
- `backoff_min` should not exceed `backoff_max`. Otherwise the second failure lowers the backoff to `backoff_max`.
- procd restarts the daemon if 30 seconds pass without a watchdog ping, and the daemon pings once per cycle. Keep `cycle` well below 30.

The hub uses only `cycle`, as its snapshot interval.
