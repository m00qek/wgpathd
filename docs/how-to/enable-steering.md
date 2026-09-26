# How to Move a Spoke from Observe to Steer

In steer mode, wgpathd moves a peer to its direct path once it has evidence and the path passes a trial. This guide switches a spoke over and checks the result.

## Prerequisites

- The spoke runs in observe mode and the relay path works: [How to configure a spoke](configure-spoke.md).
- You have a way into the spoke that does not depend on `wg_mesh`, such as `wg_hub` or the LAN. wgpathd never touches `wg_hub`.

---

## 1. Switch the mode

```bash
uci set wgpathd.main.mode='steer'
uci commit wgpathd
service wgpathd restart
```

The restart puts every peer back in RELAY. Direct has to be earned again, which takes about `n_up` cycles (15 seconds with the defaults).

If you have one anchor and one or more roamers, switch the roamers first. An anchor gets its evidence from the roamers' direct traffic, so it has nothing to act on until a roamer steers.

## 2. Watch the transitions

```bash
logread -f -e wgpathd
```

A peer going direct logs:

```
peer SpokeBmeshPublicKeyExample00000000000000000=: transition RELAY -> TRIALING (trial_start)
peer SpokeBmeshPublicKeyExample00000000000000000=: transition TRIALING -> DIRECT (trial_ok)
```

`trial_timeout` instead of `trial_ok` means the tunnel probe got no answer over the direct path within `trial_window`. The peer is back on the relay and backs off for 30 seconds, doubling on each further failure.

## 3. Check the status

```bash
ubus call wgpathd status
```

A direct peer shows `"state": "DIRECT"`, with `endpoint` and `target` set to the peer's IPv6 endpoint, and `last_change.reason` `trial_ok`. Confirm on the wire with `wg show wg_mesh endpoints`.

Once both spokes of a pair steer, both should settle in DIRECT. For a short time one side may be DIRECT while the other is still RELAY; both directions keep working.

## 4. Go back to observe

To stop steering, set the mode back and restart:

```bash
uci set wgpathd.main.mode='observe'
uci commit wgpathd
service wgpathd restart
```

Every managed peer returns to its relay endpoint on the first cycle.

For what to do when a peer does not go direct, or keeps falling back, see [How to inspect status and troubleshoot](troubleshoot.md).
