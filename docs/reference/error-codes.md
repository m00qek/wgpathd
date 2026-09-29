# Error Codes

wgpathd reports failures as uppercase codes, defined in `src/wgpathd/errors.uc`. In logs a code appears as `CODE (detail)`, or `CODE` alone when there is no text detail. A detail can itself contain a nested code, as in `INTERFACE_MISSING (wg_mesh: WG_PARSE_FAILED (no interface wg_mesh))`.

Where each code is logged is listed in [Log messages](log-messages.md).

---

## Configuration

These stop startup, fail the config check that `service wgpathd start` and `reload` run, and make a reload keep the running configuration. `service wgpathd check` shows them as readable `FAIL  config:` lines instead; see [Service commands](service-commands.md#findings).

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `CONFIG_INVALID_ROLE` | the configured role, or `unset` | `role` is not `spoke` or `hub`. |
| `CONFIG_MISSING_OPTION` | option name | A required option for the role is missing or empty. |
| `CONFIG_INVALID_OPTION` | the option's name, then what it must be: `<name> must be …` | An option has a value it cannot take: an interface option that is not a name of letters, digits and `_`, a `serve_addr` that is not an address the hub can listen on, a `serve_port` that is not a decimal port number, or a timing parameter out of its bounds or, on a spoke, in conflict with another. |
| `INTERFACE_MISSING` | interface name | From configuration: an interface option names no `network` section of type `interface`. At startup: the interface is not in the `wireguard status` reply; the detail is `<iface>: <cause>`. |

## Check

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `CHECK_INVALID_CANDIDATE` | what is wrong with the candidate | A `candidate` passed to `ubus call wgpathd.config check` does not follow its rules. It is returned as `{ "error": "CHECK_INVALID_CANDIDATE", "message": "<detail>" }` and nothing is checked; see [ubus config check](ubus-config-check.md#malformed-candidate). |

## Discovery

These make a spoke's discovery fetch fail. The spoke keeps its previous map.

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `DISCOVERY_FETCH_FAILED` | `invalid url <url>` (without any `user:password@` part), `cannot connect`, `uclient error <n>`, `timeout`, `response too large`, `HTTP <status>` | The HTTP fetch did not produce a 200 response of at most 65536 bytes within 5 seconds. |
| `DISCOVERY_INVALID_JSON` | — | The body is not a JSON object. |
| `DISCOVERY_INVALID_PEERS` | `too many peers`, `invalid public key`, or the key of the bad entry | The object has more than 64 entries, a key that is not a public key, or an invalid entry. |
| `CACHE_SAVE_FAILED` | the cache path | A valid payload could not be written to the discovery cache. The payload is used all the same. |

## Commands

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `EXEC_TIMEOUT` | the command name, `wg` | `wg set` did not exit within 2 seconds. It appears inside `WG_COMMAND_FAILED`. |

## Probes

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `PROBE_SEND_FAILED` | `<host>: <socket error>`, `raw socket: <socket error>`, `raw socket on <device>: <socket error>`, `no random bytes`, or `<host>: not an IP address` | A probe could not be sent: the raw socket could not be opened or bound to `mesh_iface`, `/dev/urandom` gave no bytes for the probe's nonce, or the kernel refused the packet, for example with `Message too large` when a full-size tunnel probe does not fit the route. The probe counts as unanswered. |

## WireGuard

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `WG_COMMAND_FAILED` | `exit <code>`, or a nested `EXEC_TIMEOUT` | `wg set <iface> peer <key> endpoint <addr> [peer <key> endpoint <addr> ...]`, one command for every peer, failed. |
| `WG_PARSE_FAILED` | `no interface <iface>`, `no peer table`, `invalid peer entry` | The `ubus call wireguard status` reply does not contain the interface, has no peer table for it, or has a peer entry with a malformed key or handshake time. |

## Routing and links

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `ROUTE_LOOKUP_FAILED` | `<host>: <error>` | The route lookup for a peer's relay host failed. The peer stays unmanaged and is rechecked every cycle. |
| `LINK_LOOKUP_FAILED` | `<iface>: <error>` | The MTU of `mesh_iface` could not be read. No tunnel probe is sent that cycle. |

## ubus

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `UBUS_CONNECT_FAILED` | — | The daemon could not connect to ubus at startup; every ubus operation then fails with this code. `service wgpathd status` reports it as `wgpathd: cannot read status: UBUS_CONNECT_FAILED`, and `service wgpathd check` skips the interfaces. |
| `UBUS_CALL_FAILED` | `<object> <method>: status <n>` for `wireguard status`, or the ubus error text | A ubus call failed: the `wireguard status` read or the watchdog ping. |
| `UBUS_PUBLISH_FAILED` | ubus error text | The `wgpathd` ubus object could not be registered, for example because another instance holds it. Stops startup. |

## Publisher

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `PUBLISHER_LISTEN_FAILED` | `<addr>:<port>: <socket error>` | The hub could not listen on `serve_addr:serve_port`. Stops startup. |
