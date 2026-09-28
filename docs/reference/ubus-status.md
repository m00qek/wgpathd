# ubus Status

While it runs, wgpathd registers the ubus object `wgpathd` with one method, `status`. It takes no arguments and changes nothing.

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
	"discovery": {
		"fresh": true,
		"last_ok": 1790456491
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
			"switches": 2,
			"last_change": {
				"ts": 1790456400,
				"from": "TRIALING",
				"to": "DIRECT",
				"reason": "trial_ok"
			}
		}
	},
	"unmanaged": [
		{
			"section": "hub",
			"pubkey": "HubMeshPublicKeyExample00000000000000000000=",
			"reason": "missing wgpathd_relay"
		}
	]
}
```

### Top level

| Field | Type | Description |
| :--- | :--- | :--- |
| `role` | string | `spoke`. |
| `mode` | string | `steer` or `observe`. An unknown configured mode shows as `observe`. |
| `discovery` | object | Discovery state; see below. |
| `peers` | object | One entry per managed peer, keyed by its `wg_mesh` public key. |
| `unmanaged` | array | Peers wgpathd does not steer; see below. |

### `discovery`

| Field | Type | Description |
| :--- | :--- | :--- |
| `fresh` | boolean | `true` if the most recent completed fetch succeeded. `false` before the first fetch completes and after any failed fetch. |
| `last_ok` | integer or null | Unix time of the last successful fetch. `null` until one succeeds. Loading the cache at startup does not set it. |

### `peers.<pubkey>`

| Field | Type | Description |
| :--- | :--- | :--- |
| `state` | string | `RELAY`, `TRIALING` or `DIRECT`. |
| `section` | string | The UCI section name of the peer in `/etc/config/network`. |
| `up_streak` | integer | Consecutive cycles with direct evidence, counted in RELAY. |
| `down_streak` | integer | Consecutive failed tunnel probes, counted in DIRECT. A probe answered over the relay counts as failed. |
| `backoff` | number | Current backoff interval in seconds; `0` means none. This is the interval, not the time remaining. |
| `ready` | boolean | `true` when `up_streak` has reached `n_up`, or in RELAY on a cycle that saw an authenticated roam. In observe mode this means steer mode would start a trial. In steer mode it can stay `true` while a backoff is still running. |
| `endpoint` | string or null | The endpoint wgpathd asserted on the last decided cycle: the relay endpoint in RELAY, the target otherwise. `null` before the first cycle. It is what wgpathd asked for, even if that `wg set` failed, and can differ from the kernel's current endpoint after a roam. |
| `target` | string or null | The direct endpoint being trialed or held. `null` in RELAY. |
| `switches` | integer | Number of state transitions since the daemon started, or since a reload added the peer or changed its annotations. Roam adoptions are not counted. |
| `last_change` | object or null | The most recent state transition; `null` if none since the peer started being managed. |

`state`, `up_streak`, `down_streak`, `backoff` and `ready` are updated at the end of each cycle in which the peer was decided. A peer skipped in a cycle (missing from the kernel, or while `wireguard status` cannot be read) keeps its previous values.

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

### `unmanaged[]`

| Field | Type | Description |
| :--- | :--- | :--- |
| `section` | string | The UCI section name of the peer in `/etc/config/network`. Anonymous sections show their generated name, such as `cfg0a8f3c`. |
| `pubkey` | string or null | The peer's `public_key` as configured; `null` if it has none. |
| `reason` | string | Why the peer is not managed. See [Substrate annotations](substrate.md#managed-and-unmanaged-peers). |

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
