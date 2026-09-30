# ubus Status

While it runs, wgpathd registers the ubus object `wgpathd` with one method, `status`. It takes no arguments and changes nothing; it accepts and ignores the `ubus_rpc_session` argument that uhttpd adds to calls from LuCI.

```bash
ubus call wgpathd status
```

If the daemon is not running, `ubus` reports `Command failed: Not found`.

This is the machine-readable interface. `service wgpathd status` prints a readable summary of the same reply; see [Service commands](service-commands.md#status).

The reply depends on the role. Fields that have no value yet are `null`.

---

## Spoke reply

```json
{
	"role": "spoke",
	"mode": "steer",
	"now": 1790456500,
	"mesh_iface": "wg_mesh",
	"hub_iface": "wg_hub",
	"params": {
		"cycle": 3,
		"n_up": 5,
		"m_down": 2,
		"tunnel_timeout": 1,
		"trial_window": 8,
		"backoff_min": 30,
		"backoff_max": 900,
		"backoff_reset": 600,
		"discovery_interval": 60,
		"give_up_after": 3,
		"give_up_pause": 21600
	},
	"discovery": {
		"fresh": true,
		"last_ok": 1790456491,
		"url": "http://10.10.0.1:7780/peers"
	},
	"peers": {
		"SpokeBmeshPublicKeyExample00000000000000000=": {
			"state": "DIRECT",
			"section": "spoke_b",
			"up_streak": 0,
			"down_streak": 0,
			"backoff": 0,
			"ready": false,
			"endpoint": "[2001:db8:b::20]:51820",
			"target": "[2001:db8:b::20]:51820",
			"candidate": "[2001:db8:b::20]:51820",
			"candidate_refused": null,
			"last_target": "[2001:db8:b::20]:51820",
			"since": 1790456400,
			"trial_deadline": null,
			"next_trial": null,
			"failed_target": null,
			"failed_trials": 0,
			"given_up": null,
			"switches": 2,
			"relayed_answers": 0,
			"last_change": {
				"ts": 1790456400,
				"from": "TRIALING",
				"to": "DIRECT",
				"reason": "trial_ok"
			}
		},
		"SpokeCmeshPublicKeyExample00000000000000000=": {
			"state": "RELAY",
			"section": "spoke_c",
			"up_streak": 3,
			"down_streak": 0,
			"backoff": 60,
			"ready": false,
			"endpoint": "10.10.0.13:51820",
			"target": null,
			"candidate": "[2001:db8:c::30]:51820",
			"candidate_refused": null,
			"last_target": "[2001:db8:c::30]:51820",
			"since": 1790456470,
			"trial_deadline": null,
			"next_trial": 1790456530,
			"failed_target": "[2001:db8:c::30]:51820",
			"failed_trials": 1,
			"given_up": null,
			"switches": 4,
			"relayed_answers": 0,
			"last_change": {
				"ts": 1790456470,
				"from": "TRIALING",
				"to": "RELAY",
				"reason": "trial_timeout"
			}
		}
	},
	"unmanaged": [
		{
			"section": "hub",
			"pubkey": "HubMeshPublicKeyExample00000000000000000000=",
			"reason": "fixed endpoint"
		}
	],
	"history": [
		{
			"ts": 1790456470,
			"section": "spoke_c",
			"pubkey": "SpokeCmeshPublicKeyExample00000000000000000=",
			"from": "TRIALING",
			"to": "RELAY",
			"reason": "trial_timeout",
			"endpoint": "10.10.0.13:51820"
		},
		{
			"ts": 1790456462,
			"section": "spoke_c",
			"pubkey": "SpokeCmeshPublicKeyExample00000000000000000=",
			"from": "RELAY",
			"to": "TRIALING",
			"reason": "trial_start",
			"endpoint": "[2001:db8:c::30]:51820"
		},
		{
			"ts": 1790456400,
			"section": "spoke_b",
			"pubkey": "SpokeBmeshPublicKeyExample00000000000000000=",
			"from": "TRIALING",
			"to": "DIRECT",
			"reason": "trial_ok",
			"endpoint": "[2001:db8:b::20]:51820"
		}
	]
}
```

### Times

Every time in the reply is an integer Unix time in seconds, from the router's clock: `now`, `discovery.last_ok`, and each peer's `since`, `trial_deadline`, `next_trial`, `given_up.since`, `given_up.until`, `last_change.ts` and `history[].ts`. `now` is the router's time when it answered, so a client computes an age as `now - ts` and a wait as `ts - now`, whatever its own clock says: `since` 1790456470 with `now` 1790456500 is 30 seconds ago, `next_trial` 1790456530 is in 30 seconds.

Apart from `discovery.last_ok`, these times are kept on the monotonic clock and converted when the reply is built, against the same `now`. A step of the router's wall clock, such as NTP setting it after boot, therefore shifts them all together and leaves every difference to `now` correct. `discovery.last_ok` is read from the wall clock when the fetch succeeds, so it does not move with such a step.

### Top level

| Field | Type | Description |
| :--- | :--- | :--- |
| `role` | string | `spoke`. |
| `mode` | string | `steer` or `observe`. An unknown configured mode shows as `observe`. |
| `now` | integer | Unix time when the reply was built. See [Times](#times). |
| `mesh_iface` | string | The configured `mesh_iface`. |
| `hub_iface` | string | The configured `hub_iface`. |
| `params` | object | The timing parameters in effect, defaults and overrides merged, as numbers: `cycle`, `n_up`, `m_down`, `tunnel_timeout`, `trial_window`, `backoff_min`, `backoff_max`, `backoff_reset`, `discovery_interval`, `give_up_after`, `give_up_pause`. See [Timing parameters](parameters.md). |
| `discovery` | object | Discovery state; see below. |
| `peers` | object | One entry per managed peer, keyed by its `wg_mesh` public key. |
| `unmanaged` | array | Peers wgpathd does not steer; see below. |
| `history` | array | The most recent state changes across all peers, newest first; see below. |

### `discovery`

| Field | Type | Description |
| :--- | :--- | :--- |
| `fresh` | boolean | `true` if the most recent completed fetch succeeded. `false` before the first fetch completes and after any failed fetch. |
| `last_ok` | integer or null | Unix time of the last successful fetch. `null` until one succeeds. Loading the cache at startup does not set it. |
| `url` | string | The configured `discovery` URL: the scheme, host, port and path only: never the `user:password@` part, the query or the fragment. A value that does not read as `scheme://host[:port]` shows as `(unreadable url)`. |

### `peers.<pubkey>`

| Field | Type | Description |
| :--- | :--- | :--- |
| `state` | string | `RELAY`, `TRIALING` or `DIRECT`. |
| `section` | string | The UCI section name of the peer in `/etc/config/network`. |
| `up_streak` | integer | Consecutive cycles with direct evidence, counted in RELAY. |
| `down_streak` | integer | Consecutive failed tunnel probes, counted in DIRECT. A probe answered over the relay counts as failed. |
| `backoff` | number | Current backoff interval in seconds; `0` means none. This is the interval, not the time remaining. |
| `ready` | boolean | `true` when `up_streak` has reached `n_up`, or in RELAY on a cycle that saw an authenticated roam; `false` while the echo points at an address that is given up (see `given_up`), since steer mode would not trial it. In observe mode this means steer mode would start a trial. In steer mode it can stay `true` while a backoff is still running. |
| `endpoint` | string or null | The endpoint wgpathd asserted on the last decided cycle: the relay endpoint in RELAY, the target otherwise. `null` before the first cycle. It is what wgpathd asked for, even if that `wg set` failed, and can differ from the kernel's current endpoint after a roam. |
| `target` | string or null | The direct endpoint being trialed or held. `null` in RELAY. |
| `candidate` | string or null | The peer's direct endpoint in the discovery map: from the last successful fetch, or from the cache until one succeeds. `null` if the map has none. A trial takes this endpoint, unless the peer roamed to another direct address first, or it is refused. |
| `candidate_refused` | string or null | Why `candidate` is not taken for this peer, as of the last cycle: `own address`, `relay address`, `tunnel address` or `routes into <iface>`; see [Discovery HTTP API](discovery-api.md#spoke-side-validation). `null` when it is taken, when there is none, and before the first cycle. |
| `last_target` | string or null | The direct endpoint most recently trialed or held, kept after the peer falls back to RELAY: in RELAY after a `trial_timeout` or `demoted`, the address that failed. It follows roams while DIRECT. `null` until the first trial since the peer started being managed. |
| `since` | integer | Unix time when the current state began: the last transition, or, before any, when the peer started being managed. |
| `trial_deadline` | integer or null | In TRIALING, the Unix time at which the trial times out unless an answer proves it first. `null` in the other states. |
| `next_trial` | integer or null | In RELAY in steer mode, while a backoff runs, the Unix time it ends: the earliest a trial can start. The trial also needs the peer to be `ready`. `null` otherwise: no backoff running, another state, or observe mode. |
| `failed_target` | string or null | The direct endpoint whose trials timed out, the last `failed_trials` of them in a row. `null` before any trial timed out, and after a trial commits. |
| `failed_trials` | integer | Trials in a row that timed out on `failed_target`; `0` when it is `null`. A timeout on another target starts again at `1`. Demotions are not counted. |
| `given_up` | object or null | Set while `failed_target` is given up: it reached `give_up_after` failed trials, and the underlay echo alone starts no trial toward it. `null` otherwise. See [Giving up an address](../explanation/state-machine.md#giving-up-an-address). |
| `switches` | integer | Number of state transitions since the daemon started, or since a reload added the peer or changed its settings. Roam adoptions are not counted. |
| `relayed_answers` | integer | Tunnel probe answers after which the kernel endpoint was the relay, over the same span as `switches`. It grows while the peer's side is in RELAY and sends traffic, whose packets move the kernel endpoint back onto the relay. Such an answer does not commit a trial but does hold DIRECT, so a count that keeps growing while the peer is DIRECT can mean a direct path that no longer carries traffic. |
| `last_change` | object or null | The most recent state transition; `null` if none since the peer started being managed. |

`state`, `up_streak`, `down_streak`, `backoff` and `ready` are updated at the end of each cycle in which the peer was decided. A peer skipped in a cycle (missing from the kernel, or while `wireguard status` cannot be read) keeps its previous values.

### `peers.<pubkey>.given_up`

| Field | Type | Description |
| :--- | :--- | :--- |
| `since` | integer | Unix time of the trial timeout that gave the address up. |
| `until` | integer | `since` plus `give_up_pause`: from then on the echo may start one more trial toward the address, the backoff permitting. A roam, or another address from discovery that answers the echo, starts a trial sooner. It stays set, possibly in the past, until a trial starts. |

### `peers.<pubkey>.last_change`

| Field | Type | Description |
| :--- | :--- | :--- |
| `ts` | integer | Unix time of the transition. |
| `from` | string | Previous state. |
| `to` | string | New state. |
| `reason` | string | One of the reasons below. |

| Reason | Transition |
| :--- | :--- |
| `trial_start` | RELAY → TRIALING |
| `trial_ok` | TRIALING → DIRECT |
| `trial_timeout` | TRIALING → RELAY |
| `demoted` | DIRECT → RELAY after `m_down` failed probes |
| `observe_mode` | TRIALING or DIRECT → RELAY because the mode is not `steer` |

### `history[]`

The last 20 transitions and roam adoptions of all managed peers, newest first; entries in the same cycle are listed in reverse peer order. Giving an address up, and resuming trials, change no path and are not listed: the trial timeout before a give-up is, and the peer's `given_up` and the log show the rest. It is kept in memory: a restart of the daemon, including the one a structural reload causes, empties it. A reload that removes or changes a peer keeps its entries.

| Field | Type | Description |
| :--- | :--- | :--- |
| `ts` | integer | Unix time of the change. For a transition it equals the peer's `last_change.ts`. |
| `section` | string | The peer's UCI section name in `/etc/config/network`, when the change happened. |
| `pubkey` | string | The peer's public key. |
| `from` | string | Previous state. |
| `to` | string | New state. For a roam adoption, `DIRECT`, like `from`. |
| `reason` | string | One of the [reasons](#peerspubkeylast_change) of a transition, or `roam_adopted`: a DIRECT peer followed an authenticated roam to another direct address, which `switches` does not count. |
| `endpoint` | string | The endpoint asserted after the change: the relay endpoint after a change to RELAY, the direct target otherwise. The same as `endpoint=` in the log line for the change. |

### `unmanaged[]`

| Field | Type | Description |
| :--- | :--- | :--- |
| `section` | string | The UCI section name of the peer in `/etc/config/network`. Anonymous sections show their generated name, such as `cfg0a8f3c`. |
| `pubkey` | string or null | The peer's `public_key` as configured; `null` if it has none. |
| `reason` | string | Why the peer is not managed. See [Managed and unmanaged peers](uci-config.md#managed-and-unmanaged-peers). |

## Hub reply

```json
{
	"role": "hub",
	"peers": {
		"SpokeAmeshPublicKeyExample00000000000000000=": {
			"direct": "[2001:db8:a::1]:51820",
			"handshake_age": 12
		},
		"SpokeBmeshPublicKeyExample00000000000000000=": {
			"direct": "[2001:db8:b::20]:51820",
			"handshake_age": 7
		}
	}
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `role` | string | `hub`. |
| `peers` | object | The current discovery snapshot, exactly as served on `GET /peers`. See [Discovery HTTP API](discovery-api.md#response-body). |

The snapshot is refreshed every `cycle`. If a read of `read_iface` fails, the previous snapshot is kept.
