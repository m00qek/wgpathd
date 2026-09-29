# ubus Config Check

The package registers the ubus object `wgpathd.config` with three read-only methods:

| Method | Answers |
| :--- | :--- |
| [`check`](#check) | The configuration check of [`service wgpathd check`](service-commands.md#check), for the saved configuration or for values that are not saved yet. |
| [`peers`](#peers) | The WireGuard interfaces, and the name, public key and description of each peer of one of them. |
| [`schema`](#schema) | Every timing parameter with its default and bounds. |

```bash
ubus call wgpathd.config check
ubus call wgpathd.config check '{"candidate": {"main": {"mode": "steer"}}}'
ubus call wgpathd.config peers
ubus call wgpathd.config schema
```

None of them changes anything. rpcd serves the object through the plugin `/usr/share/rpcd/ucode/wgpathd.uc`, so it answers whether or not the daemon runs, is enabled or has a valid configuration. rpcd loads the plugin when it starts or reloads; the package reloads rpcd when it is installed, upgraded or removed. The plugin reads the configuration afresh on every call.

Who may call it is up to rpcd's ACLs. The `wgpathd` package ships none; `luci-app-wgpathd` grants all three methods to its pages (see [Files and dependencies](files.md#acl)). Grant them as you would grant reading the configuration. A caller learns from the replies what the router holds: the WireGuard interfaces, the section names, public keys and descriptions of their peers, which peers have settings, through the relay and discovery route checks, whether the router would reach any address the caller puts in a candidate's `relay` or `discovery`, and by which interface, and, through the firewall lines, the firewall zones of the interfaces wgpathd uses and whether the firewall accepts wgpathd's traffic. It learns no private or preshared key, endpoint or allowed IP from `/etc/config/network`, and nothing else of `/etc/config/firewall`. The plugin reads both files itself, as root inside rpcd, so a caller needs no access to either.

---

## check

`check` runs the full check of `service wgpathd check`, in the same order and with the same wording, except the lines that need `ubus call wireguard status`.

### What it checks

| Included | Left out |
| :--- | :--- |
| The `config:` lines, and the loader failure if the configuration does not load | `<iface>: up, <n> peer(s)` and the other interface lines |
| `service disabled (option enabled '<value>'): it will not start` | `peer <section>: not in <mesh_iface> yet, skipped until it appears` |
| For a hub, whether `serve_addr` is an address of a WireGuard interface | |
| For a spoke, one line per peer: the relay route check of each steered peer and the reason each other one is not steered | `ubus unavailable: interfaces not checked` |
| The warnings about `peer` sections that match no mesh peer, and about options left over in `/etc/config/network` | |
| The `firewall:` lines, from `/etc/config/firewall` and the nftables files fw4 includes | |

The interface lines are left out because rpcd itself serves `wireguard status`, through `rpcd-mod-wireguard`, and cannot answer that call while it waits for it inside the plugin. For those lines, run `service wgpathd check` on the router.

The relay route of each steered peer is looked up in the router's routing table, as the daemon does at startup, and so is the route to the discovery host when the URL gives an address.

Each finding is described in [Service commands](service-commands.md#findings).

### Request

| Argument | Type | Description |
| :--- | :--- | :--- |
| `candidate` | object, optional | Values to check instead of the saved ones. Without it, `check` checks `/etc/config/wgpathd`, `/etc/config/network` and `/etc/config/firewall` as `service wgpathd check` reads them. |

rpcd refuses a `candidate` that is not an object, and any other argument, with `Invalid argument` (`UBUS_STATUS_INVALID_ARGUMENT`).

#### `candidate`

```json
{
	"main": {
		"mode": "steer",
		"cycle": ""
	},
	"peers": {
		"O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=": {
			"relay": "10.10.0.12:51820",
			"tunnel": "10.20.0.12"
		}
	}
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `main` | object, optional | Options of the `main` section of `/etc/config/wgpathd`, by name. Any option name made of letters, digits and `_`. |
| `peers` | object, optional | The [`peer` sections](uci-config.md#peer-sections) of `/etc/config/wgpathd`, by public key. Each value is an object with `relay`, `tunnel`, or both. |

Values are merged over the saved configuration, option by option:

- An option given with a string replaces the saved value.
- An option given as an empty string, `""`, removes the saved option, as clearing a field in a form does.
- A number is taken as its decimal text: `45` is `'45'`, `0.5` is `'0.5'`.
- Any option not given keeps its saved value, including every option of a section the candidate does not name.
- `main` may be given when `/etc/config/wgpathd` has no `main` section; its options then make up the whole section.
- A peer is named by its WireGuard public key. Its values are merged over the `peer` section with that key; when there is none, they make up a new one. When several sections have the key, each gets the values.
- A peer left with neither `relay` nor `tunnel` has no `peer` section, as clearing both fields of a peer in a form removes its section.
- A key that is no peer of `mesh_iface` is accepted, and checked as a stale `peer` section. The candidate cannot change anything in `/etc/config/network` or `/etc/config/firewall`.
- The merged values are checked as if they were saved: which peers are read depends on the merged `mesh_iface`, so a candidate that changes `mesh_iface` checks the peers of the new interface.

Nothing is written, staged or committed: a later call without `candidate` checks the saved configuration again. Changes staged but not committed with the `uci` command are part of the saved configuration here, as they are for `service wgpathd check`; changes staged in LuCI are not, since rpcd keeps them per session.

### Reply

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
			"public_key": "O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=",
			"message": "peer spoke_b: relay 10.10.0.12:51820 via wg_hub, probes 10.20.0.12"
		},
		{
			"level": "fail",
			"subject": "peer",
			"section": "spoke_c",
			"public_key": "hQrcvDZE8wGkiQzp3/zDaTL3dY0PfbFTcQ4r3sG1UUk=",
			"option": "relay",
			"message": "peer spoke_c: not steered (invalid relay)"
		},
		{
			"level": "warn",
			"subject": "firewall",
			"option": "hub_iface",
			"message": "firewall: UDP port 51820 (relayed WireGuard) from wg_hub (zone vpn): no rule accepts it",
			"fix": {
				"uci": "uci add firewall rule\nuci set firewall.@rule[-1].name='Allow-wgpathd-relay'\nuci set firewall.@rule[-1].src='vpn'\nuci set firewall.@rule[-1].proto='udp'\nuci set firewall.@rule[-1].dest_port='51820'\nuci set firewall.@rule[-1].target='ACCEPT'\nuci commit firewall\nservice firewall reload",
				"config": "config rule\n\toption name 'Allow-wgpathd-relay'\n\toption src 'vpn'\n\toption proto 'udp'\n\toption dest_port '51820'\n\toption target 'ACCEPT'"
			}
		}
	]
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `ok` | boolean | `false` if any finding has the level `fail`; the exit status of `service wgpathd check` would be `1`. |
| `findings` | array | The findings, in the order `service wgpathd check` prints them. |

#### `findings[]`

| Field | Type | Description |
| :--- | :--- | :--- |
| `level` | string | `ok`, `skip`, `warn` or `fail`. `service wgpathd check` prints `fail` as `FAIL`. |
| `subject` | string | `config` for the configuration and the `enabled` option, `peer` for a peer or a `peer` section, `firewall` for the firewall. (`service wgpathd check` also uses the interface name and `ubus`, for the lines left out here.) |
| `section` | string | The section of `/etc/config/network` the finding is about: for `peer`, the peer's section; for `config`, a section with options left over from an earlier release. Left out for a `peer` section that matches no mesh peer. |
| `public_key` | string | For `peer`, the peer's public key, when it is a valid key. It names the peer's [`peer` section](uci-config.md#peer-sections) in `/etc/config/wgpathd`. |
| `option` | string | Present when the finding is about one option: the loader failures that name one (`role`, a missing option, an option with an invalid value), `mode` for an unknown mode, `enabled`, `discovery` for the warnings about the discovery host, `serve_addr` for a listener address outside the WireGuard interfaces, and for a peer the option of its `peer` section that is missing or malformed (`relay`, `tunnel`), `relay` for a relay routed into the mesh, or `public_key` for a peer in `/etc/config/network` without a valid key; for the firewall, the option the traffic follows from: `mesh_iface` for the tunnel probe, `hub_iface` for relayed packets, `serve_port` for the peer list. Left out otherwise, for example for `no interface <name> in /etc/config/network`, `configured more than once` or the underlay probe. |
| `message` | string | The line `service wgpathd check` prints after the level, word for word. |
| `fix` | object | For a firewall finding that is not `ok`, when there is a zone and a port to name: the rule that would accept the traffic. `service wgpathd check` prints it under the line. Left out otherwise. |
| `fix.uci` | string | The rule as `uci` commands, one per line, ending with `uci commit firewall` and `service firewall reload`. |
| `fix.config` | string | The same rule as a `config rule` section of `/etc/config/firewall`, one line per option, indented with a tab. |

`section`, `public_key` and `option` name UCI sections and options, so a client can attach a finding to the field it is about; `message` and `fix` are for showing, as text. The firewall messages and rules hold names from `/etc/config/firewall` and `/etc/config/network`; zone names are only those fw4 accepts, letters, digits and `_./-`.

#### Malformed candidate

A `candidate` that does not follow the rules above is not checked. The reply is:

```json
{
	"error": "CHECK_INVALID_CANDIDATE",
	"message": "peers: 'spoke_b' is not a WireGuard public key"
}
```

| `message` | Cause |
| :--- | :--- |
| `candidate must be an object` | `candidate` is not an object. |
| `unknown part '<name>'` | `candidate` has a field other than `main` and `peers`. |
| `main must be an object`, `peers must be an object`, `peers.<key> must be an object` | A part is not an object. |
| `main: unknown option '<name>'` | An option name with characters other than letters, digits and `_`. |
| `peers: '<key>' is not a WireGuard public key` | A peer is named by anything but a public key: 43 base64 characters followed by `=`. |
| `peers.<key>: unknown option '<name>'` | A peer option other than `relay` and `tunnel`, including `public_key` and the `wgpathd_relay` and `wgpathd_tunnel` of earlier releases. |
| `main.<name> must be a string or a number`, `peers.<key>.<name> must be a string or a number` | A value is a boolean, an array or an object. |

## peers

Lists the WireGuard interfaces of `/etc/config/network`, and the peers of one of them, for a client that must name the peers without reading `/etc/config/network`, which holds every private key of the router.

```bash
ubus call wgpathd.config peers
ubus call wgpathd.config peers '{"iface": "wg_hub"}'
```

### Request

| Argument | Type | Description |
| :--- | :--- | :--- |
| `iface` | string, optional | The interface whose peers to list: the name of an `interface` section with `proto 'wireguard'`. Without it, the interface of the saved role: `mesh_iface` on a spoke, `read_iface` on a hub. |

An `iface` that is not the plain name of a WireGuard interface, the empty string included, is answered `{ "error": "PEERS_INVALID_IFACE", "message": "iface must name a WireGuard interface of /etc/config/network" }`, and no peer is read.

### Reply

```json
{
	"iface": "wg_mesh",
	"interfaces": [ "wg_hub", "wg_mesh" ],
	"peers": [
		{ "section": "spoke_b", "public_key": "O0LYRo/RVGHReCajupP1UioYUPELAkI8jPy1rWoazG4=", "description": "beach" },
		{ "section": "hub", "public_key": "W+1CXUTTLNuEuF+fANM4a1F4kUcjzH1oH9VYWI9eA00=" }
	]
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `iface` | string or null | The interface listed. `null` when no `iface` was given and the saved role names no WireGuard interface, for example while `role` is unset; `peers` is then empty. |
| `interfaces` | array of strings | Every `interface` section with `proto 'wireguard'`, sorted by name. |
| `peers` | array | Every section of type `wireguard_<iface>`, in the order of `/etc/config/network`. |
| `peers[].section` | string | The section name; for an anonymous section, the id UCI gave it, such as `cfg09cdcd`. |
| `peers[].public_key` | string or null | The peer's `public_key` as written, or `null` when it has none. |
| `peers[].description` | string | The peer's `description`, when it has one. |

Nothing else of a peer or an interface is returned: no private or preshared key, endpoint, allowed IP, listen port or address.

## schema

Lists the [timing parameters](parameters.md) the `main` section takes, for a client that builds a form from them rather than from a list of its own. The **Timing** tab of the LuCI settings page is built from it.

```json
{
	"parameters": [
		{ "name": "cycle", "default": 3, "min": 1, "max": 10, "whole": false },
		{ "name": "n_up", "default": 5, "min": 1, "max": 100, "whole": true }
	]
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `parameters` | array | Every parameter, in the order of [Timing parameters](parameters.md). |
| `parameters[].name` | string | The option name. |
| `parameters[].default` | number | The value used when the option is not set. |
| `parameters[].min`, `parameters[].max` | number | The bounds, both included. |
| `parameters[].whole` | boolean | `true` when only whole numbers are taken. |

The bounds alone do not make a valid set: on a spoke some parameters must also agree, which only [`check`](#check) tells. See [Timing parameters](parameters.md#bounds).
