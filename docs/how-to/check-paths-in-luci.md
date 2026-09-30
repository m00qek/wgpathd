# How to Check Mesh Paths in LuCI

This guide shows how to see, in the LuCI web interface, which path each mesh peer uses and why. It needs the `luci-app-wgpathd` package, which `make package` builds next to wgpathd as `bin/luci-app-wgpathd-0.1.0-r7.apk`. Copy it to the router and install it as in [Installing wgpathd](install.md#3-install-it):

```bash
apk add --allow-untrusted /tmp/luci-app-wgpathd-0.1.0-r7.apk
```

Then log in to LuCI again, so it shows the new menu entries.

---

## Open the page

Go to **Status → Mesh paths**. The page refreshes by itself; there is no need to reload it.

If it says **The wgpathd service is not running**, enable and check the service under **Network → Mesh paths** ([How to configure mesh paths in LuCI](configure-in-luci.md)), or follow [The service is not running](troubleshoot.md#the-service-is-not-running).

## Read the path of each peer

The **Peers** table has one row per steered peer:

| Label | Path drawn | Meaning |
| :--- | :--- | :--- |
| **Direct** | this router ─ peer, solid | Traffic goes straight to the peer's public IPv6 address. |
| **Via hub** | this router ┄ hub ┄ peer, dashed | Traffic is relayed through the hub. |
| **Testing direct** | this router ··· peer, dotted | wgpathd is trying the direct path; it goes back to the hub if the test gets no answer. |

**Endpoint** is the address WireGuard sends to now, **For** how long the peer has been in this state, and **Switches** how many times it changed state since the service started.

Peers that wgpathd does not steer are greyed out, with the reason next to them. [A peer is missing from peers](troubleshoot.md#a-peer-is-missing-from-peers) says how to fix each reason.

## Find out why a peer uses the hub

Click **Show details** on the peer's row. For a peer via the hub you see:

- the direct address it tried last, and the one the hub publishes now;
- if this router does not try the published address, why not: it is one of this router's own addresses, the peer's relay endpoint or tunnel address, or it is routed into `wg_mesh` or `wg_hub`. See [Discovery HTTP API](../reference/discovery-api.md#spoke-side-validation);
- why it uses the hub, for example that a number of checks in a row got no answer over the direct path;
- when it tries the direct path next. After each failed try it waits longer, up to the `backoff_max` of [Timing parameters](../reference/parameters.md).

After several failed tests in a row on the same address, 3 by default, the row gets a **Direct given up** label. The details then say after how many failed tests, and when wgpathd tries the address again: once its pause of 6 hours by default is over, or as soon as the hub publishes another address or the peer reaches this router directly. [The direct address is given up](troubleshoot.md#the-direct-address-is-given-up) explains why, and how to retry at once.

For a peer testing the direct path, the details say when the test ends.

**Recent changes** lists the last 20 changes of all peers, newest first. The list is kept in memory since the service started; the system log has every change.

## Notice observe mode and a stale peer list

- In observe mode a note at the top says so. Every peer stays on the hub; a **Would test direct** label marks the peers steer mode would try, and a **Direct given up** label the peers whose address an earlier run in steer mode gave up, which steer mode would not try yet. See [Moving a Spoke from Observe to Steer](enable-steering.md).
- If the spoke cannot fetch the peer list from the hub, a warning says how old the last good list is. The **Service** table shows the list's address and age.

## Glance at it from the Overview

**Status → Overview** has a short **Mesh paths** section with the path and state of each steered peer, what happens next, such as when a given-up direct address is tried again, and a **Details** link to the full page. It is hidden while the service is not running, on a hub, and when no peer is steered.

## On the hub

On the hub the page lists the **Published peers**: the direct address the hub publishes for each spoke, and how long ago the hub last heard from it. A spoke not heard from for more than 3 minutes is greyed out.
