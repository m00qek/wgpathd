# How to Inspect Status and Troubleshoot

Two sources tell you what wgpathd is doing: its ubus status and its log.

```bash
ubus call wgpathd status
logread -e wgpathd
```

Every status field is described in [ubus status](../reference/ubus-status.md), and every log line in [Log messages](../reference/log-messages.md). This guide goes from symptom to cause.

---

## The service is not running

`ubus call wgpathd status` answers `Command failed: Not found`.

1. Look at the last lines of `logread -e wgpathd`. An `invalid configuration:` or `startup failed:` line names the problem as an [error code](../reference/error-codes.md).
2. For `INTERFACE_MISSING`: with `invalid configuration:`, no UCI interface section has that name, so check the spelling in `/etc/config/wgpathd`. With `startup failed:`, the section exists but the interface is not up; check `ubus call wireguard status`.
3. For a hub with `PUBLISHER_LISTEN_FAILED`, `serve_addr` is not assigned on this host, often because `wg_hub` is down, or another process holds the port.
4. Fix the cause and run `service wgpathd restart`. procd also retries every 5 seconds on its own.

## A peer is missing from `peers`

The peer is not managed. Find it in the `unmanaged` array of the status; `reason` says why. The reasons are listed in [Substrate annotations](../reference/substrate.md#managed-and-unmanaged-peers).

- `missing ...` or `invalid ...`: fix the annotation in `/etc/config/network`, then restart wgpathd. Annotations are only read at startup.
- `relay routes into wg_mesh`: some `wg_mesh` peer's `allowed_ips` covers the relay address. Remove it, make sure the hub's `wg_hub` peer holds the transit range, then restart. Check with `ip route get <relay address>`; it must say `dev wg_hub`.
- `relay route lookup failed: ...`: usually `wg_hub` was not up yet. wgpathd retries every cycle and logs `relay route found, now managed` when it succeeds.

A managed peer that is missing from the kernel's peer table is skipped and logged as `absent from wg_mesh, skipped`. Check `wg show wg_mesh`; the peer returns to normal once netifd has it again.

## A peer never becomes ready

`up_streak` stays at 0 and `ready` stays `false`. The peer has no direct evidence.

- **Roamer side (it should reach an anchor):**
    - `discovery.fresh` is `false`: the spoke cannot fetch from the hub. See `discovery failed:` lines in the log, and try `uclient-fetch -qO- <discovery URL>`.
    - The peer's key is not in the hub's published list: the hub has no IPv6 endpoint for it. On the hub, check `ubus call wgpathd status`.
    - `ping -6 <peer IPv6 address>` fails: the peer's host does not answer ICMPv6 echo, or the address is stale.
- **Anchor side:** an anchor usually cannot ping a roamer behind a stateful firewall. Its evidence comes from the roamer's direct packets. Make sure the roamer is in steer mode and has reached DIRECT.
- **Neither side is inbound-reachable:** the pair stays on the relay. That is the intended result.

## A peer is ready but never trials

- `mode` is `observe`. Trials only happen in steer mode: [How to move a spoke from observe to steer](enable-steering.md).
- `backoff` is not 0: a trial waits until the backoff since the last failure has passed. `ready` can be `true` in the meantime.

## Trials time out

The log shows `TRIALING -> RELAY (trial_timeout)` again and again, with `backoff` growing.

The direct endpoint answers ping, but WireGuard traffic does not get through both ways. Common causes:

- The anchor does not accept UDP `51820` from WAN over IPv6.
- The endpoint published by the hub has a port that does not reach the peer's `wg_mesh`, for example because of port translation.
- The peer does not answer the tunnel probe: its firewall lacks the `wgpathd: tunnel probe` rule, or its mesh interface is not named `wg_mesh`. Check `nft list ruleset | grep wgpathd:` on the peer.
- One direction is broken. The trial needs a round trip, so one-way loss correctly fails it.

## A peer keeps falling back

The log alternates `trial_ok` and `DIRECT -> RELAY (demoted)`. The direct path passes a trial, then loses `m_down` tunnel probes in a row.

wgpathd already damps this: each demotion doubles the backoff up to 15 minutes, so a flapping path ends up parked on the relay. If the path is merely lossy, raising `m_down` makes it more tolerant. See [How to tune timing parameters](tune-timing.md).

## Endpoints change on every cycle

`wg show wg_mesh endpoints` flips between the relay and a direct address while the status says RELAY. This is normal when the other side is DIRECT and this side is not yet: this side re-asserts the relay each cycle, and the other side's direct packets roam it back. It ends when this side promotes, or stays like this while its backoff runs. Both directions keep working.

## The log repeats the same warning

- `discovery failed:` is logged on every failed fetch, up to every 10 seconds while the hub is unreachable. Fix discovery, or ignore it while the hub is down; direct paths that work are not affected.
- `watchdog ping failed:` on every cycle means procd does not know the service. This happens when the daemon is started by hand instead of through `service wgpathd start`.
- `setting endpoint ... failed:` means `wg set` itself fails. Check that `wg` is installed and the interface exists.
