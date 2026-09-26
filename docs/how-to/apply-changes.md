# How to Apply Configuration Changes

wgpathd picks up changes to `/etc/config/wgpathd` and to the peer annotations in `/etc/config/network` on a reload, without losing the state of the peers you did not touch.

## Prerequisites

- wgpathd is configured and running: [How to configure the hub](configure-hub.md) or [How to configure a spoke](configure-spoke.md).

---

## 1. Make the change

Edit the file, or use `uci`. For example, to switch a spoke to steer mode:

```bash
uci set wgpathd.main.mode='steer'
uci commit wgpathd
```

If you changed WireGuard peers in `/etc/config/network`, not only their `wgpathd_` options, also apply them to the interface with `service network reload`.

## 2. Check it

```bash
service wgpathd check
```

Fix every `FAIL` line. A reload refuses a configuration that fails, and the daemon keeps running with the old one.

## 3. Reload

```bash
service wgpathd reload
```

If you apply changes with LuCI's Save & Apply, or with `reload_config`, this happens by itself.

## 4. Confirm

```bash
logread -e wgpathd | tail -n 3
```

- `configuration reloaded: 2 peers kept, 1 added, 0 removed`: the change is live. Kept peers carry on as they were; added and changed peers start in RELAY.
- `reload: mesh_iface changed, exiting for procd to start afresh`, followed about 5 seconds later by `started as spoke`: the change needed a new process. Every peer starts again in RELAY.
- `invalid configuration, keeping the running one`: the check failed. Go back to step 2.

Which changes apply live and which need a new process is listed in [Service commands](../reference/service-commands.md#reload).

## When to restart instead

Run `service wgpathd restart` when you want the daemon to start from scratch:

- after an upgrade, so the new code runs;
- after fixing the routes of a peer rejected with `relay routes into wg_mesh`, if its annotations did not change: a reload keeps that verdict;
- to put every peer back on the relay and let each earn direct again.

## To turn the service off or on

```bash
uci set wgpathd.main.enabled='0'
uci commit wgpathd
service wgpathd reload
```

The reload stops the daemon, and it will not start at boot while `enabled` is `0`. Set it back to `1` and reload to start it again. Each peer keeps the endpoint it had when the daemon stopped.
