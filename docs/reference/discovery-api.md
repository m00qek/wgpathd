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

A JSON object keyed by WireGuard public key. It contains every peer of the hub's `read_iface` whose current endpoint could be a direct path: an IPv6 address that is not unspecified (`::`), loopback (`::1`), multicast (`ff00::/8`), link-local (`fe80::/10`), IPv4-mapped (`::ffff:0:0/96`), IPv4-compatible (`::/96`), NAT64 (`64:ff9b::/96`, `64:ff9b:1::/48`) or discard-only (`100::/64`). Global and unique local (`fc00::/7`) addresses are published. Peers with an IPv4 endpoint, another IPv6 endpoint or no endpoint are left out. With no such peers, the body is `{}`.

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
- At most 2 connections from one source address are open at once, the address compared in its canonical form. A third from the same address is served, and that address's oldest connection is closed without a reply.
- At most 16 connections are open at once. When all 16 are open, a new connection from another address is served, and the oldest open connection is closed without a reply.
- Every open connection is one still waiting for its request: an answered one is closed at once. So a client that opens connections and sends nothing cannot keep a client from another address out; at worst it takes a slow client's place, and that client's request fails like a timeout. A spoke sends its request as soon as it connects.
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

One invalid entry rejects the whole payload. A valid entry whose address could not be a direct path, one that is unspecified (`::`), loopback (`::1`), multicast (`ff00::/8`), link-local (`fe80::/10`), IPv4-mapped (`::ffff:0:0/96`), IPv4-compatible (`::/96`), NAT64 (`64:ff9b::/96`, `64:ff9b:1::/48`) or discard-only (`100::/64`), is left out alone, and the rest of the payload is taken: it is one peer's address, not a broken payload, and that peer simply has no candidate. The same rule applies to the cache when it is loaded. On any failure the spoke keeps its previous map, sets `discovery.fresh` to `false` in the [status](ubus-status.md) and logs `discovery failed: <code> (<detail>)`.

A valid payload replaces the spoke's map and is written to `/var/run/wgpathd/cache.json`. Entries whose key is not one of the spoke's managed peers are ignored. The `handshake_age` field is accepted but not used in any decision.

Every cycle, before probing, the spoke also refuses a peer's candidate that this router must not take as that peer's direct endpoint, whose address is:

| Reason | The address is |
| :--- | :--- |
| `own address` | an address of this router |
| `relay address` | the host of the `relay` in the peer's [`peer` section](uci-config.md#peer-sections) |
| `tunnel address` | the `tunnel` in the peer's `peer` section |
| `routes into <iface>` | routed out of `mesh_iface` or `hub_iface`, where a WireGuard endpoint would loop into a tunnel |

A refused candidate is neither probed nor trialed: a peer in RELAY stays there, unless it roams to a direct address by itself. The refusal is logged when it starts or its reason changes, and when it ends, and the peer's status shows it in `candidate_refused`. A candidate whose route cannot be looked up is not refused: its probes fail on their own. The refusal applies to candidates only; an authenticated roam is taken as before.
