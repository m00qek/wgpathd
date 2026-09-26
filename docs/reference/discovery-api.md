# Discovery HTTP API

The hub serves the discovery snapshot over plain HTTP on `serve_addr:serve_port`. Spokes fetch it from the URL in their `discovery` option. This page describes both sides.

---

## Endpoint

```
GET /peers
```

No query parameters, headers or body are used.

```bash
curl -s http://10.10.0.1:7780/peers
```

## Response body

A JSON object keyed by WireGuard public key. It contains every peer of the hub's `read_iface` whose current endpoint is IPv6. Peers with an IPv4 endpoint or no endpoint are left out. With no such peers, the body is `{}`.

```json
{
	"SpokeAmeshPublicKeyExample00000000000000000=": {
		"direct": "[2001:db8:a::1]:51820",
		"handshake_age": 12
	},
	"SpokeBmeshPublicKeyExample00000000000000000=": {
		"direct": "[2001:db8:b::20]:51820"
	}
}
```

| Field | Type | Description |
| :--- | :--- | :--- |
| `direct` | string | The peer's current endpoint as the hub's kernel sees it, in canonical `[v6]:port` form. |
| `handshake_age` | integer | Seconds between the hub's clock at snapshot time and the peer's last handshake, never negative. Omitted if the peer has never completed a handshake. |

The body reflects the snapshot taken on the hub's last cycle, not a live read.

## Status codes

The server checks the request line in this order.

| Status | Condition | Body |
| :--- | :--- | :--- |
| `400 Bad Request` | The first line is not `<METHOD> <path> HTTP/1.0` or `HTTP/1.1`, with an uppercase method | `{ "error": "bad request" }` |
| `405 Method Not Allowed` | Method is not `GET` (including `HEAD`) | `{ "error": "method not allowed" }` |
| `404 Not Found` | Path is not exactly `/peers` (a query string also gives 404) | `{ "error": "not found" }` |
| `200 OK` | `GET /peers` | The snapshot |

Every reply is `HTTP/1.0` with these headers, after which the server closes the connection:

```
Content-Type: application/json
Content-Length: <bytes>
Connection: close
```

## Connection handling

- One request per connection. The request is complete at the first blank line (`\r\n\r\n` or `\n\n`); anything after it is ignored.
- A request larger than 4096 bytes without a blank line is closed without a reply.
- A connection that has not completed its request within 2 seconds is closed without a reply.
- At most 16 connections are open at once. Further connections are accepted and closed immediately.
- Requests never run a command on the hub; they are answered from memory.

## Spoke-side validation

A spoke fetches the URL with an HTTP GET. The fetch counts as failed, with the listed [error code](error-codes.md), in these cases:

| Condition | Code | Detail |
| :--- | :--- | :--- |
| The URL cannot be parsed | `DISCOVERY_FETCH_FAILED` | `invalid url <url>` |
| The connection or request cannot start | `DISCOVERY_FETCH_FAILED` | `cannot connect` |
| A transport error occurs | `DISCOVERY_FETCH_FAILED` | `uclient error <code>` |
| No complete response within 5 seconds | `DISCOVERY_FETCH_FAILED` | `timeout` |
| The body exceeds 65536 bytes | `DISCOVERY_FETCH_FAILED` | `response too large` |
| The HTTP status is not 200 | `DISCOVERY_FETCH_FAILED` | `HTTP <status>` |
| The body is not a JSON object | `DISCOVERY_INVALID_JSON` | — |
| The object has more than 64 entries | `DISCOVERY_INVALID_PEERS` | `too many peers` |
| A key is not a WireGuard public key | `DISCOVERY_INVALID_PEERS` | `invalid public key` |
| An entry is invalid (see below) | `DISCOVERY_INVALID_PEERS` | the entry's key |

An entry is valid when it is an object whose `direct` is a valid `[v6]:port` endpoint with port 1–65535, and whose `handshake_age`, if present, is an integer of zero or more. Other fields are ignored.

One invalid entry rejects the whole payload. On any failure the spoke keeps its previous map, sets `discovery.fresh` to `false` in the [status](ubus-status.md) and logs `discovery failed: <code> (<detail>)`.

A valid payload replaces the spoke's map and is written to `/var/run/wgpathd/cache.json`. Entries whose key is not one of the spoke's managed peers are ignored. The `handshake_age` field is accepted but not used in any decision.
