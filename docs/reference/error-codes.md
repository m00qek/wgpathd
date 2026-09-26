# Error Codes

wgpathd reports failures as uppercase codes, defined in `src/wgpathd/errors.uc`. In logs a code appears as `CODE (detail)`, or `CODE` alone when there is no text detail. A detail can itself contain a nested code, as in `INTERFACE_MISSING (wg_mesh: WG_PARSE_FAILED (no interface wg_mesh))`.

Where each code is logged is listed in [Log messages](log-messages.md).

---

## Configuration

These stop startup.

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `CONFIG_INVALID_ROLE` | the configured role, or `unset` | `role` is not `spoke` or `hub`. |
| `CONFIG_MISSING_OPTION` | option name | A required option for the role is missing or empty. |
| `CONFIG_INVALID_OPTION` | parameter name | A timing parameter is not a positive decimal number. |
| `INTERFACE_MISSING` | interface name | From configuration: an interface option names no `network` section of type `interface`. At startup: the interface is not in the `wireguard status` reply; the detail is `<iface>: <cause>`. |

## Discovery

These make a spoke's discovery fetch fail. The spoke keeps its previous map.

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `DISCOVERY_FETCH_FAILED` | `invalid url <url>`, `cannot connect`, `uclient error <n>`, `timeout`, `response too large`, `HTTP <status>` | The HTTP fetch did not produce a 200 response of at most 65536 bytes within 5 seconds. |
| `DISCOVERY_INVALID_JSON` | — | The body is not a JSON object. |
| `DISCOVERY_INVALID_PEERS` | `too many peers`, `invalid public key`, or the key of the bad entry | The object has more than 64 entries, a key that is not a public key, or an invalid entry. |

## Commands

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `EXEC_TIMEOUT` | the command name, `wg` or `ping` | A command did not exit within its time limit. For a probe this counts as no answer; for `wg set` it appears inside `WG_COMMAND_FAILED`. |

## WireGuard

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `WG_COMMAND_FAILED` | `exit <code>`, or a nested `EXEC_TIMEOUT` | `wg set <iface> peer <key> endpoint <addr>` failed. |
| `WG_PARSE_FAILED` | `no interface <iface>`, `no peer table`, `invalid peer entry` | The `ubus call wireguard status` reply does not contain the interface, has no peer table for it, or has a peer entry with a malformed key or handshake time. |

## Routing

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `ROUTE_LOOKUP_FAILED` | `<host>: <error>` | The route lookup for a peer's relay host failed. The peer stays unmanaged and is rechecked every cycle. |

## ubus

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `UBUS_CONNECT_FAILED` | — | The daemon could not connect to ubus at startup; every ubus operation then fails with this code. |
| `UBUS_CALL_FAILED` | `<object> <method>: status <n>` for `wireguard status`, or the ubus error text | A ubus call failed: the `wireguard status` read or the watchdog ping. |
| `UBUS_PUBLISH_FAILED` | ubus error text | The `wgpathd` ubus object could not be registered, for example because another instance holds it. Stops startup. |

## Publisher

| Code | Detail | Trigger |
| :--- | :--- | :--- |
| `PUBLISHER_LISTEN_FAILED` | `<addr>:<port>: <socket error>` | The hub could not listen on `serve_addr:serve_port`. Stops startup. |
