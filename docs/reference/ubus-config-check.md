# ubus Config Check

The package registers the ubus object `wgpathd.config` with one method, `check`. It validates the configuration with the same loader and the same checks as [`service wgpathd check`](service-commands.md#check), and can validate values that are not saved yet. It changes nothing.

```bash
ubus call wgpathd.config check
ubus call wgpathd.config check '{"candidate": {"main": {"mode": "steer"}}}'
```

rpcd serves the object through the plugin `/usr/share/rpcd/ucode/wgpathd.uc`, so it answers whether or not the daemon runs, is enabled or has a valid configuration. rpcd loads the plugin when it starts or reloads; the package reloads rpcd when it is installed, upgraded or removed. Who may call it is up to rpcd's ACLs: the package ships none.

---

## What it checks

`check` runs the full check of `service wgpathd check`, in the same order and with the same wording, except the lines that need `ubus call wireguard status`:

| Included | Left out |
| :--- | :--- |
| The `config:` lines, and the loader failure if the configuration does not load | `<iface>: up, <n> peer(s)` and the other interface lines |
| `service disabled (option enabled '<value>'): it will not start` | `peer <section>: not in <mesh_iface> yet, skipped until it appears` |
| For a spoke, one line per peer: the relay route check of each steered peer and the annotation reason of each other one | `ubus unavailable: interfaces not checked` |

The interface lines are left out because rpcd itself serves `wireguard status`, through `rpcd-mod-wireguard`, and cannot answer that call while it waits for it inside the plugin. For those lines, run `service wgpathd check` on the router.

The relay route of each steered peer is looked up in the router's routing table, as the daemon does at startup.

Each finding is described in [Service commands](service-commands.md#findings).

## Request

| Argument | Type | Description |
| :--- | :--- | :--- |
| `candidate` | object, optional | Values to check instead of the saved ones. Without it, `check` checks `/etc/config/wgpathd` and `/etc/config/network` as `service wgpathd check` reads them. |

rpcd refuses a `candidate` that is not an object, and any other argument, with `Invalid argument` (`UBUS_STATUS_INVALID_ARGUMENT`).

### `candidate`

```json
{
	"main": {
		"mode": "steer",
		"cycle": ""
	},
	"peers": {
		"spoke_b": {
			"wgpathd_relay": "10.10.0.12:51820",
			"wgpathd_tunnel": "10.20.0.12"
		}
	}
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `main` | object, optional | Options of the `main` section of `/etc/config/wgpathd`, by name. Any option name made of letters, digits and `_`. |
| `peers` | object, optional | Peer annotations by the peer's section name in `/etc/config/network`. Each value is an object with `wgpathd_relay`, `wgpathd_tunnel`, or both. |

Values are merged over the saved configuration, option by option:

- An option given with a string replaces the saved value.
- An option given as an empty string, `""`, removes the saved option, as clearing a field in a form does.
- A number is taken as its decimal text: `45` is `'45'`, `0.5` is `'0.5'`.
- Any option not given keeps its saved value, including every option of a section the candidate does not name.
- `main` may be given when `/etc/config/wgpathd` has no `main` section; its options then make up the whole section.
- A peer section must already exist in `/etc/config/network` with a type of the form `wireguard_<interface>`. The candidate cannot add, remove or rename a peer, and it cannot change `public_key`.
- The merged values are checked as if they were saved: which peers are read depends on the merged `mesh_iface`, so a candidate that changes `mesh_iface` checks the peers of the new interface.

Nothing is written, staged or committed: a later call without `candidate` checks the saved configuration again. Changes staged but not committed with the `uci` command are part of the saved configuration here, as they are for `service wgpathd check`; changes staged in LuCI are not, since rpcd keeps them per session.

## Reply

```json
{
	"ok": false,
	"findings": [
		{
			"level": "ok",
			"subject": "config",
			"message": "config: spoke, mode steer, 1 steered peer, 1 not steered"
		},
		{
			"level": "warn",
			"subject": "config",
			"option": "enabled",
			"message": "service disabled (option enabled '0'): it will not start"
		},
		{
			"level": "ok",
			"subject": "peer",
			"section": "spoke_b",
			"message": "peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12"
		},
		{
			"level": "fail",
			"subject": "peer",
			"section": "spoke_c",
			"option": "wgpathd_relay",
			"message": "peer spoke_c: not steered (invalid wgpathd_relay)"
		}
	]
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `ok` | boolean | `false` if any finding has the level `fail`; the exit status of `service wgpathd check` would be `1`. |
| `findings` | array | The findings, in the order `service wgpathd check` prints them. |

### `findings[]`

| Field | Type | Description |
| :--- | :--- | :--- |
| `level` | string | `ok`, `skip`, `warn` or `fail`. `service wgpathd check` prints `fail` as `FAIL`. |
| `subject` | string | `config` for the configuration and the `enabled` option, `peer` for a peer. (`service wgpathd check` also uses the interface name and `ubus`, for the lines left out here.) |
| `section` | string | Only for `peer`: the peer's section name in `/etc/config/network`. |
| `option` | string | Present when the finding is about one option: the loader failures that name one (`role`, a missing option, an invalid timing parameter), `mode` for an unknown mode, `enabled`, and for a peer the annotation that is missing or malformed (`wgpathd_relay`, `wgpathd_tunnel`, `public_key`) or `wgpathd_relay` for a relay routed into the mesh. Left out otherwise, for example for `no interface <name> in /etc/config/network`. |
| `message` | string | The line `service wgpathd check` prints after the level, word for word. |

`section` and `option` name UCI sections and options, so a client can attach a finding to the field it is about; `message` is for showing.

### Malformed candidate

A `candidate` that does not follow the rules above is not checked. The reply is:

```json
{
	"error": "CHECK_INVALID_CANDIDATE",
	"message": "no wireguard peer section 'spoke_z' in /etc/config/network"
}
```

| `message` | Cause |
| :--- | :--- |
| `unknown part '<name>'` | `candidate` has a field other than `main` and `peers`. |
| `main must be an object`, `peers must be an object`, `peers.<section> must be an object` | A part is not an object. |
| `main: unknown option '<name>'` | An option name with characters other than letters, digits and `_`. |
| `peers.<section>: unknown option '<name>'` | A peer option other than `wgpathd_relay` and `wgpathd_tunnel`. |
| `main.<name> must be a string or a number`, `peers.<section>.<name> must be a string or a number` | A value is a boolean, an array or an object. |
| `no wireguard peer section '<section>' in /etc/config/network` | The section does not exist, or is not a WireGuard peer. |
