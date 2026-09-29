# How to Inspect Status and Troubleshoot

Three commands tell you what wgpathd is doing and what it needs:

```bash
service wgpathd status     # state of every peer
service wgpathd check      # configuration and substrate
logread -e wgpathd         # what happened
```

To watch every message as it happens, including routine detail, stop the service and run the daemon in the foreground, where it also writes to the terminal: `service wgpathd stop; /usr/libexec/wgpathd/daemon.uc`. Press Ctrl+C and run `service wgpathd start` when done.

`ubus call wgpathd status` has every field, such as `up_streak`, `ready` and `backoff`. The output of each is described in [Service commands](../reference/service-commands.md), [ubus status](../reference/ubus-status.md) and [Log messages](../reference/log-messages.md). This guide goes from symptom to cause.

---

## The service is not running

`service wgpathd status` does not print `running`.

1. If it prints `disabled (option enabled in /etc/config/wgpathd)`, set `option enabled '1'` and run `service wgpathd start`.
2. Run `service wgpathd check` and fix every `FAIL` line. `start` refuses a configuration that fails the check, and says so with `invalid configuration, not starting`; nothing retries it.
3. If the check passes, look at the last lines of `logread -e wgpathd`. A `startup failed:` line names the problem as an [error code](../reference/error-codes.md), and procd retries every 5 seconds.
    - `INTERFACE_MISSING`: the interface is not up; check `ubus call wireguard status`.
    - `PUBLISHER_LISTEN_FAILED` on a hub: `serve_addr` is not assigned on this host, often because `wg_hub` is down, or another process holds the port.
4. Fix the cause and run `service wgpathd start`.

## A peer is missing from `peers`

The peer is not managed. Find it under `unmanaged` in the status, or in the `peer` lines of `service wgpathd check`; the reason says why. The reasons are listed in [Managed and unmanaged peers](../reference/uci-config.md#managed-and-unmanaged-peers).

- `not configured`: the peer has no `peer` section in `/etc/config/wgpathd`, or its `public_key` there differs from the one in `/etc/config/network`. Add or fix it as in [How to configure a spoke](configure-spoke.md#1-write-the-configuration), then run `service wgpathd reload`. If `service wgpathd check` warns about options left over in `/etc/config/network`, see [How to upgrade from a release that kept peer settings in the network configuration](upgrade-peer-settings.md).
- `configured more than once`: two `peer` sections have the peer's key. Remove one, then run `service wgpathd reload`.
- `missing ...` or `invalid ...`: fix the `relay` or `tunnel` of the peer's `peer` section in `/etc/config/wgpathd` (or its `public_key` in `/etc/config/network`), then run `service wgpathd reload`.
- `relay routes into wg_mesh`: some `wg_mesh` peer's `allowed_ips` covers the relay address. Remove it and make sure the hub's `wg_hub` peer holds the transit range. Check with `ip route get <relay address>`; it must say `dev wg_hub`, and `service wgpathd check` must show the peer as `ok`. Then run `service wgpathd reload`: the reload guards the peer again and logs `peer <section> (<key prefix>): relay route found, now managed`.
- `relay route lookup failed: ...`: usually `wg_hub` was not up yet. wgpathd retries every cycle and logs `relay route found, now managed` when it succeeds.

A managed peer that is missing from the kernel's peer table is skipped and logged as `absent from wg_mesh, skipped`. Check `wg show wg_mesh`; the peer returns to normal once netifd has it again, logged as `back in wg_mesh`.

## A peer never becomes ready

`up_streak` stays at 0 and `ready` stays `false`. The peer has no direct evidence.

- **Roamer side (it should reach an anchor):**
    - Discovery is `stale` (`discovery.fresh` is `false`): the spoke cannot fetch from the hub. See `discovery failed:` lines in the log, and try `uclient-fetch -qO- <discovery URL>`. A `Connection refused` usually means the hub's firewall rejects the port: `service wgpathd check` on the hub says so in its `firewall:` line.
    - The peer's key is not in the hub's published list: the hub has no IPv6 endpoint for it, or none that could be a direct path. On the hub, check `service wgpathd status`.
    - `candidate_refused` is set: this router will not take the published address, and the log says why in `candidate refused endpoint=<endpoint> reason=<reason>`. An `own address` or `routes into <iface>` usually means a route or an address on this router covers the peer's public address; see [Discovery HTTP API](../reference/discovery-api.md#spoke-side-validation).
    - `ping -6 <peer IPv6 address>` fails: the peer's host does not answer ICMPv6 echo, for example because its firewall lost OpenWrt's `Allow-ICMPv6-Input` (its `service wgpathd check` says so), or the address is stale.
- **Anchor side:** an anchor usually cannot ping a roamer behind a stateful firewall. Its evidence comes from the roamer's direct packets. Make sure the roamer is in steer mode and has reached DIRECT.
- **Neither side is inbound-reachable:** the pair stays on the relay. That is the intended result.

## A peer is ready but never trials

- `mode` is `observe`. Trials only happen in steer mode: [How to move a spoke from observe to steer](enable-steering.md). In observe mode the log says `ready, steer would trial endpoint=<endpoint>` when a peer becomes ready.
- `backoff` is not 0: a trial waits until the backoff since the last failure has passed. `ready` can be `true` in the meantime.

## Trials time out

The log shows `transition TRIALING -> RELAY reason=trial_timeout backoff=<s>s` again and again, with the backoff growing, until the address is [given up](#the-direct-address-is-given-up).

The direct endpoint answers ping, but WireGuard traffic does not get through both ways. Common causes:

- The anchor does not accept UDP `51820` from WAN over IPv6.
- The endpoint published by the hub has a port that does not reach the peer's `wg_mesh`, for example because of port translation.
- The peer does not answer the tunnel probe: its firewall does not accept ICMP echo requests from the zone of its `wg_mesh`. Run `service wgpathd check` on the peer: its `firewall:` line for the tunnel probe says so, with the rule to add. See [How to open the firewall for wgpathd](open-firewall.md).
- One direction is broken. The trial needs a round trip, so one-way loss correctly fails it.
- The path drops large packets. The tunnel probe fills the `wg_mesh` MTU, so a direct path that only carries smaller packets, for example over a link with a lower MTU that drops what does not fit, fails the trial. Lower the `wg_mesh` MTU on both sides until full-size packets cross, or leave the peer on the relay.
- The other side is in RELAY and sends a lot of traffic through the relay. Its packets move this side's endpoint back onto the relay, and an answer that comes back that way does not count. On a healthy path a trial still gets through between those packets, and the other side then trials on the roam; if it is held by its own backoff, this side waits for that backoff to run out.

Each failed trial also cuts that peer's traffic for up to `trial_window`. After `give_up_after` of them in a row (3) on the same address, wgpathd stops testing it; see [What a trial costs](../explanation/state-machine.md#what-a-trial-costs).

## The direct address is given up

The log shows `direct address given up endpoint=<endpoint> failed_trials=<n> pause=<s>s`, and `given_up` is set for the peer in `ubus call wgpathd status`. After `give_up_after` trials in a row on that address timed out, wgpathd stopped testing it on the underlay echo alone, so the peer's traffic no longer pays for a failed trial every backoff. The peer stays on the relay; `up_streak` goes on counting the echo answers, but `ready` stays `false`.

It tests again by itself, logged as `direct address trials resumed reason=<reason>`, when:

- the peer's packets arrive directly, for example when the other side tests the path (`roam`),
- the hub publishes another address for the peer that answers ping (`new_candidate`),
- the time in `given_up.until` has passed, `give_up_pause` after the give-up, 6 hours by default (`pause_over`). This is one trial: if it fails, the address is given up again at once.

Once you have fixed the cause, one of those in [Trials time out](#trials-time-out), you need not wait: `service wgpathd restart` forgets the give-up, and the peer earns direct again from scratch. A reload keeps it. To give up sooner or later, see [How to tune timing parameters](tune-timing.md).

## A peer keeps falling back

The log alternates `reason=trial_ok` and `transition DIRECT -> RELAY reason=demoted`. The direct path passes a trial, then loses `m_down` tunnel probes in a row.

wgpathd already damps this: each demotion doubles the backoff up to 15 minutes, so a flapping path ends up parked on the relay. If the path is merely lossy, raising `m_down` makes it more tolerant. See [How to tune timing parameters](tune-timing.md).

## Endpoints change on every cycle

`wg show wg_mesh endpoints` flips between the relay and a direct address while the status says RELAY. This is normal when the other side is DIRECT and this side is not yet: this side re-asserts the relay each cycle, and the other side's direct packets roam it back. This side trials on the first such roam, so it ends within a cycle or two, or stays like this while its backoff runs. Both directions keep working. While it lasts, this side's own traffic reaches the other side through the relay and roams that side back as well, which shows there as a growing `relayed_answers`.

## Both sides are DIRECT but traffic still uses the relay

Both peers show `DIRECT`, yet `wg show wg_mesh endpoints` keeps showing the relay on one side or both, and `relayed_answers` in `ubus call wgpathd status` grows every cycle. Site-to-site latency sits between the direct and the relay figures.

This is WireGuard's roaming, not a wgpathd fault. Its endpoint follows the last authenticated packet, from whichever path. When both sides switch from the relay to direct while traffic flows steadily between them, packets already on their way through the relay arrive after the switch, since the relay is slower, and move the endpoint back. Each side then sends through the relay again, and moves the other one back in turn. wgpathd re-asserts the direct endpoint every cycle, but steady traffic with no pause longer than the relay's extra latency can keep the two bouncing for as long as it lasts. In the lab, with 20 ms added to the relay round trip and a steady 100 packets/s, it did not settle within two minutes.

Nothing is lost: all traffic still arrives, part of it over the relay. It ends at the first pause in the traffic. If it persists, check that the direct path is really healthy: a direct path that died while the peer was DIRECT looks the same, since relayed answers still hold DIRECT (see [Relay traffic and the proof](../explanation/state-machine.md#relay-traffic-and-the-proof)). A short pause in the traffic, or `service wgpathd restart` on one side, tells the two apart: on a healthy path the endpoints settle on the direct addresses.

## The log shows an outage

Repeated failures are logged once, when they start, and again with `recovered` when they end. A `failed` line with no `recovered` after it means the problem is still there.

- `discovery failed:`: the spoke cannot fetch from the hub. Fix discovery, or wait while the hub is down; direct paths that work are not affected.
- `watchdog ping failed:`: procd does not know the service. This happens when the daemon is started by hand instead of through `service wgpathd start`.
- `saving the discovery cache failed:`: `/var/run/wgpathd` cannot be written, usually because the tmpfs is full. The payload is used all the same.
- `setting endpoints on <iface> failed:`: the cycle's single `wg set` failed, so no endpoint was set and no tunnel probe was sent. Check that `wg` is installed and the interface exists.
- `reading the MTU of <iface> failed:`: the mesh interface is missing, so no tunnel probe could be sized or sent.
- `sending probes failed:`: a probe could not be sent, for example because the mesh interface was being recreated or a probe did not fit the route's MTU.
