# How to Tune Timing Parameters

The defaults suit a few sites on ordinary broadband: fall back to the relay in about 6 seconds, return to direct after about 15 seconds of evidence plus a trial. Change them only when you have a reason, such as a lab where you want faster transitions, or a path that flaps.

---

## Set a parameter

Each parameter is an option in the `main` section of `/etc/config/wgpathd`. For example, to require 10 cycles of evidence instead of 5:

```bash
uci set wgpathd.main.n_up='10'
uci commit wgpathd
service wgpathd restart
```

To go back to the default, delete the option:

```bash
uci delete wgpathd.main.n_up
uci commit wgpathd
service wgpathd restart
```

A value that is not a positive decimal number stops the daemon with `invalid configuration: CONFIG_INVALID_OPTION (<name>)`. All names, defaults and exact semantics are in [Timing parameters](../reference/parameters.md).

## Common adjustments

**Fall back faster or slower.** The time to leave a dead direct path is about `m_down × cycle`. Lower `m_down` to `1` to fall back on the first missed probe; raise it if a lossy link causes needless fallbacks.

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

- `trial_window` should be more than twice `cycle`. The tunnel probe answer is read one cycle after it is sent, and the deadline is checked first, so a window of two cycles or less gives the trial at most one chance and often none.
- `tunnel_timeout` should be at least `1`. The probes run `ping -W1`; a lower limit cuts them off before a slow reply can arrive. A higher value does not make `ping` wait longer.
- `backoff_min` should not exceed `backoff_max`. Otherwise the second failure lowers the backoff to `backoff_max`.
- procd restarts the daemon if 30 seconds pass without a watchdog ping, and the daemon pings once per cycle. Keep `cycle` well below 30.

The hub uses only `cycle`, as its snapshot interval.
