# UCI Configuration

wgpathd reads `/etc/config/wgpathd` at startup and again on every `service wgpathd reload`. Most options apply on reload; `role` and the interface and listener options restart the daemon. The full list is in [Service commands](service-commands.md#reload).

The service options live in one section of type `wgpathd` named `main`. On a spoke, each mesh peer to steer has a section of type `peer` as well; see [Peer sections](#peer-sections). Sections of other types are ignored.

What wgpathd reads from `/etc/config/network` is listed in [WireGuard substrate](substrate.md).

---

## `enabled`

| Option | Required | Default | Values |
| :--- | :--- | :--- | :--- |
| `enabled` | No | on | `0`, `no`, `off`, `false` or `disabled` turn it off; anything else, or no value, leaves it on. |

While it is off, `service wgpathd start` starts no daemon, `service wgpathd reload` stops a running one, and `service wgpathd check` warns. The daemon itself does not read this option.

## `role`

| Option | Required | Values |
| :--- | :--- | :--- |
| `role` | Yes | `spoke` or `hub` |

Any other value, or no value, stops startup with `CONFIG_INVALID_ROLE`. The detail is the value given, or `unset`.

## Spoke options

```
config wgpathd 'main'
	option role       'spoke'
	option mesh_iface 'wg_mesh'
	option hub_iface  'wg_hub'
	option discovery  'http://10.10.0.1:7780/peers'
	option mode       'observe'
```

| Option | Required | Default | Description |
| :--- | :--- | :--- | :--- |
| `mesh_iface` | Yes | — | The WireGuard interface whose peer endpoints are steered. Must be a name of letters, digits and `_`, and a `network` section of type `interface`, and must appear in the `ubus call wireguard status` reply at startup. Its peers are read from `wireguard_<mesh_iface>` sections. |
| `hub_iface` | Yes | — | The hub tunnel interface. Must be a name of letters, digits and `_`, and a `network` section of type `interface`. Checked at startup only; wgpathd does not otherwise use it. |
| `discovery` | Yes | — | URL of the hub's discovery endpoint, for example `http://10.10.0.1:7780/peers`: `http://`, in lower case, a host, an optional port from `1` to `65535`, and a path. `https` is refused: the daemon has no TLS context to fetch it with. A host name is accepted, but `service wgpathd check` warns about it, because the fetch waits for its DNS lookup, and the full check warns when the host's route does not leave via `hub_iface`. See [Discovery HTTP API](discovery-api.md). |
| `mode` | No | `observe` | `steer` lets wgpathd move peers to direct paths. `observe` keeps every managed peer on its relay endpoint. Any other value runs as `observe` and logs a warning at startup and on reload. |

## Hub options

```
config wgpathd 'main'
	option role       'hub'
	option read_iface 'wg_mesh'
	option serve_addr '10.10.0.1'
	option serve_port '7780'
```

| Option | Required | Default | Description |
| :--- | :--- | :--- | :--- |
| `read_iface` | Yes | — | The WireGuard interface whose peer endpoints are published. Must be a name of letters, digits and `_`, and a `network` section of type `interface`, and must appear in the `ubus call wireguard status` reply at startup. |
| `serve_addr` | Yes | — | Local address the discovery listener binds to: one literal IPv4 or IPv6 address, which wgpathd uses in its canonical form. A host name, the wildcard addresses `0.0.0.0` and `::`, a multicast or broadcast address, and an IPv6 link-local address (which needs a zone) are refused. `service wgpathd check` warns when it is not an address of a WireGuard interface. |
| `serve_port` | Yes | — | TCP port of the discovery listener: a decimal number from `1` to `65535`, without spaces, leading zeros or other notations. The firewall must accept it from the hub tunnel; see [Firewall rules](firewall.md#peer-list). |

The hub ignores `mode`.

## Peer sections

On a spoke, each mesh peer that wgpathd steers has one section of type `peer`. The section is found by the peer's public key, so it may be anonymous, and it does not follow a rename of the peer's section in `/etc/config/network`. A hub reads no `peer` section.

```
config peer
	option public_key 'SpokeBmeshPublicKeyExample00000000000000000='
	option relay      '10.10.0.12:51820'
	option tunnel     '10.20.0.12'
```

| Option | Required | Format | Description |
| :--- | :--- | :--- | :--- |
| `public_key` | Yes | WireGuard public key: 43 base64 characters followed by `=` | The key of a peer section of type `wireguard_<mesh_iface>` in `/etc/config/network`. |
| `relay` | Yes | Endpoint: `v4:port` or `[v6]:port`, port 1–65535 | The endpoint used on the relay path: the peer's address on the hub tunnel and the peer's `wg_mesh` listen port. Its route must leave via an interface other than `mesh_iface`. |
| `tunnel` | Yes | IPv4 or IPv6 address, no port | The peer's address inside `wg_mesh`. Target of the tunnel probe. Must be inside the peer's `allowed_ips`. |

Endpoints and addresses are used in canonical form (lowercase, compressed IPv6), so `[2001:DB8::0001]:51820` and `[2001:db8::1]:51820` are the same.

A `peer` section whose `public_key` is no peer of `mesh_iface`, or that has no `public_key`, is stale: wgpathd ignores it, and `service wgpathd check` warns about it with `peer settings for <key>: no such peer in <mesh_iface>, ignored` or `peer settings without a public_key: ignored`.

Releases up to 4 kept `relay` and `tunnel` as the options `wgpathd_relay` and `wgpathd_tunnel` of the peer's section in `/etc/config/network`. Those options are no longer read. The package moves them here on upgrade; see [How to upgrade from a release that kept peer settings in the network configuration](../how-to/upgrade-peer-settings.md).

### Managed and unmanaged peers

A mesh peer is **managed** when it has exactly one `peer` section, with a valid `relay` and `tunnel`, and the route to its relay address leaves via an interface other than `mesh_iface`. wgpathd steers only managed peers.

Any other peer of `mesh_iface` is **unmanaged**: wgpathd never touches its endpoint. Unmanaged peers are logged at startup and on reload, reported by `service wgpathd check`, and listed in the `unmanaged` array of [`ubus call wgpathd status`](ubus-status.md). The checks run in this order; the first failure is the reason reported.

| Reason | Cause | Check level | Rechecked |
| :--- | :--- | :--- | :--- |
| `invalid public_key` | The peer's `public_key` in `/etc/config/network` is missing or not a valid key | `FAIL` | On reload |
| `not configured` | No `peer` section has the peer's key | `skip` | On reload |
| `configured more than once` | Two or more `peer` sections have the peer's key | `FAIL` | On reload |
| `missing relay` | The `peer` section has no `relay` | `FAIL` | On reload |
| `invalid relay` | `relay` is not a valid `v4:port` or `[v6]:port` | `FAIL` | On reload |
| `missing tunnel` | The `peer` section has no `tunnel` | `FAIL` | On reload |
| `invalid tunnel` | `tunnel` is not a valid IP address | `FAIL` | On reload |
| `relay routes into <mesh_iface>` | The route to the relay host leaves via `mesh_iface` | `FAIL` | On reload |
| `relay route lookup failed: <error>` | The route lookup for the relay host failed, for example because `wg_hub` is not up yet | `warn` | Every cycle |

Every reload reads the `peer` sections again and repeats the route check, so fixing a peer and reloading is enough. A peer waiting on a failed route lookup is also rechecked at the start of every cycle. Either way, a peer whose relay route now leaves via another interface becomes managed, starting in RELAY, and wgpathd logs `relay route found, now managed`. A waiting peer whose route resolves into `mesh_iface` becomes unmanaged with `relay routes into <mesh_iface>`.

The spoke's own `wg_mesh` peer for the hub normally has no `peer` section, so it is always listed as unmanaged with `not configured`. That is expected: the hub peer keeps its static endpoint.

## Timing parameters

Both roles accept the timing parameters as options in the `main` section, for example `option cycle '2'`. Each is optional and overrides one default. The full list, defaults and meanings are in [Timing parameters](parameters.md).

A parameter value must be a decimal number: digits, optionally followed by a dot and more digits, within the parameter's bounds; `n_up`, `m_down` and `give_up_after` take whole numbers only. `3`, `2.5` and `900` are in that form; `-1`, `1e3`, `0x10` and `3s` are not. On a spoke, `backoff_max` must be at least `backoff_min` and `trial_window` longer than `cycle` plus `tunnel_timeout`. An invalid value stops startup with `CONFIG_INVALID_OPTION`; the detail names the parameter and what it must be, for example `cycle must be a number from 1 to 10`. The bounds are in [Timing parameters](parameters.md#bounds).

## Validation order

The configuration is checked in this order, by the daemon at startup and on reload, and by `service wgpathd check`. The first failure is the one reported. At startup it stops the daemon with exit status 1 and an `invalid configuration:` log message; `service wgpathd start` and `reload` run the same check first and refuse to start or reload.

1. `role` is `spoke` or `hub` — else `CONFIG_INVALID_ROLE`.
2. Every required option for the role is a non-empty string — else `CONFIG_MISSING_OPTION` naming the first missing option, in the order listed above.
3. Every required option has the form it must have, in the order listed above — else `CONFIG_INVALID_OPTION`. An interface option is a name of letters, digits and `_`: UCI's other ways to address a section, such as `@interface[0]`, are refused, and the value is looked up only as a name. On a spoke, `discovery` is checked, and on a hub `serve_addr` and `serve_port`, as described above.
4. Every interface option names a `network` section of type `interface` — else `INTERFACE_MISSING` naming the value.
5. Every timing parameter present is within its bounds, in the order of [Timing parameters](parameters.md), and on a spoke the parameters agree — else `CONFIG_INVALID_OPTION`.

On a spoke, the mesh peers are then loaded with their `peer` sections. A peer with a problem does not stop startup; it is reported as unmanaged. See [Managed and unmanaged peers](#managed-and-unmanaged-peers).

## Shipped default

The package installs `/etc/config/wgpathd` with `option enabled '0'` and no other active option. It holds a commented-out example for each role, for a timing override and for a `peer` section. With it, the service does not start, and `service wgpathd check` fails with `option role must be 'spoke' or 'hub' (is unset)`. It is a conffile: an upgrade keeps your edits.
