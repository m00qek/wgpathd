# How to Configure Mesh Paths in LuCI

This guide sets up wgpathd from the LuCI web interface instead of `/etc/config/wgpathd`: the role, the peers a spoke steers and, if you need them, the timing parameters. The page checks the settings before it applies them.

## Prerequisites

- wgpathd and `luci-app-wgpathd` are installed: [How to install wgpathd](install.md) and [How to check mesh paths in LuCI](check-paths-in-luci.md).
- The WireGuard interfaces and their peers are set up, as in [How to prepare the WireGuard substrate](prepare-substrate.md). The page chooses among them; it does not create them.

---

## 1. Open the page

Go to **Network → Mesh paths**. The page works whether or not the service runs; a note at the top says when it does not.

If a note says **This router has no WireGuard interface yet**, set up the interfaces first.

## 2. Choose the role on the General tab

Tick **Enable**, then choose the **Role**. The tab shows only the fields of that role.

On a spoke:

- **Mode**: start with **Observe**, which watches the paths but never switches them. Switch to **Steer** once [Status → Mesh paths](check-paths-in-luci.md) shows what wgpathd would do.
- **Mesh interface**: the interface whose peers wgpathd steers, for example `wg_mesh`.
- **Hub interface**: the interface to the hub, for example `wg_hub`.
- **Peer list URL**: the hub's address on the hub interface, its port and `/peers`, for example `http://10.10.0.1:7780/peers`.

On the hub:

- **Mesh interface**: the interface whose peers the hub publishes.
- **Publish on** and **Port**: the hub's address on the spokes' tunnel, and a port, so that only the spokes reach the list.

## 3. Give each peer a relay endpoint and a tunnel address

On a spoke, open the **Peers** tab. It lists every peer of the mesh interface, by its section name and description in the network configuration.

For each peer to steer, fill in:

- **Relay endpoint**: the peer's address on the hub tunnel and its mesh listen port, for example `10.10.0.12:51820`.
- **Tunnel address**: the peer's address inside the mesh, which must be in its allowed IPs, for example `10.20.0.12`.

**Steered** shows **Yes** once both are set. Leave the hub's own row empty. To stop steering a peer, clear both fields.

## 4. Change timing only if you need to

The **Timing** tab has one field per parameter, with its default shown in the empty field. Leave a field empty to keep the default. A value outside the parameter's bounds is marked at once. [How to tune timing parameters](tune-timing.md) says when to change them.

## 5. Check, then save and apply

Click **Check configuration**. The **Configuration check** list says, line by line, what wgpathd makes of the values in the form, saved or not:

| Label | Meaning |
| :--- | :--- |
| **OK** | As it should be. |
| **Warn** | Works, but worth a look, such as a relay route that could not be looked up yet. |
| **Skip** | Left alone on purpose, such as a peer without settings. |
| **Fail** | wgpathd would refuse the configuration, or leave the peer unsteered. |

Each **Fail** marks its field in red, and the page opens the tab that holds the first one. Fix the fields and check again.

Then click **Save & Apply**. It runs the same check first. If a line fails, it saves and applies nothing and says so above the list. Otherwise LuCI applies the change, and the running service reloads it. Look at **Status → Mesh paths** to see the peers.

---

## Let another LuCI login use the page

The page needs the `luci-app-wgpathd` ACL, which grants `/etc/config/wgpathd` and the `wgpathd` ubus objects but nothing of `/etc/config/network` ([Files and dependencies](../reference/files.md#acl)). For a login other than `root`, add the ACL to its section in `/etc/config/rpcd`, with rpcd's `unauthenticated` group and `luci-base`, which every LuCI login needs:

```
config login
	option username 'meshadmin'
	option password '$p$meshadmin'
	list read 'unauthenticated'
	list read 'luci-base'
	list read 'luci-app-wgpathd'
	list write 'luci-base'
	list write 'luci-app-wgpathd'
```

`$p$meshadmin` takes the password of the system user `meshadmin`. Then run `service rpcd reload`.
