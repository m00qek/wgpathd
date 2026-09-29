# UCI Configuration

wgpathd reads `/etc/config/wgpathd` at startup and again on every `service wgpathd reload`. Most options apply on reload; `role` and the interface and listener options restart the daemon. The full list is in [Service commands](service-commands.md#reload).

All options live in one section of type `wgpathd` named `main`. Other sections are ignored.

The per-peer options that wgpathd reads from `/etc/config/network` are listed in [Substrate annotations](substrate.md).

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
| `serve_port` | Yes | — | TCP port of the discovery listener: a decimal number from `1` to `65535`, without spaces, leading zeros or other notations. The shipped firewall rule accepts port `7780`; see [Firewall rules](firewall.md). |

The hub ignores `mode`.

## Timing parameters

Both roles accept the timing parameters as options in the `main` section, for example `option cycle '2'`. Each is optional and overrides one default. The full list, defaults and meanings are in [Timing parameters](parameters.md).

A parameter value must be a decimal number: digits, optionally followed by a dot and more digits, within the parameter's bounds; `n_up` and `m_down` take whole numbers only. `3`, `2.5` and `900` are in that form; `-1`, `1e3`, `0x10` and `3s` are not. On a spoke, `backoff_max` must be at least `backoff_min` and `trial_window` longer than `cycle` plus `tunnel_timeout`. An invalid value stops startup with `CONFIG_INVALID_OPTION`; the detail names the parameter and what it must be, for example `cycle must be a number from 1 to 10`. The bounds are in [Timing parameters](parameters.md#bounds).

## Validation order

The configuration is checked in this order, by the daemon at startup and on reload, and by `service wgpathd check`. The first failure is the one reported. At startup it stops the daemon with exit status 1 and an `invalid configuration:` log message; `service wgpathd start` and `reload` run the same check first and refuse to start or reload.

1. `role` is `spoke` or `hub` — else `CONFIG_INVALID_ROLE`.
2. Every required option for the role is a non-empty string — else `CONFIG_MISSING_OPTION` naming the first missing option, in the order listed above.
3. Every required option has the form it must have, in the order listed above — else `CONFIG_INVALID_OPTION`. An interface option is a name of letters, digits and `_`: UCI's other ways to address a section, such as `@interface[0]`, are refused, and the value is looked up only as a name. On a spoke, `discovery` is checked, and on a hub `serve_addr` and `serve_port`, as described above.
4. Every interface option names a `network` section of type `interface` — else `INTERFACE_MISSING` naming the value.
5. Every timing parameter present is within its bounds, in the order of [Timing parameters](parameters.md), and on a spoke the parameters agree — else `CONFIG_INVALID_OPTION`.

On a spoke, the mesh peers are then loaded. A peer with a problem does not stop startup; it is reported as unmanaged. See [Substrate annotations](substrate.md).

## Shipped default

The package installs `/etc/config/wgpathd` with `option enabled '0'` and no other active option. It holds a commented-out example for each role and for a timing override. With it, the service does not start, and `service wgpathd check` fails with `option role must be 'spoke' or 'hub' (is unset)`. It is a conffile: an upgrade keeps your edits.
