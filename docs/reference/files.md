# Files and Dependencies

The package is `wgpathd`, version `0.1.0`, release `3`, architecture `all`, license MIT. It is built as `wgpathd-0.1.0-r3.apk`.

---

## Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/usr/libexec/wgpathd/daemon.uc` | 0755 | The daemon, run by procd. |
| `/usr/libexec/wgpathd/status.uc` | 0755 | Prints the running daemon's status as text, for `service wgpathd status`. |
| `/usr/libexec/wgpathd/check.uc` | 0755 | The validator behind `service wgpathd check`; with `--config`, the check that `start` and `reload` run. |
| `/usr/share/ucode/wgpathd/*.uc` | 0644 | The ucode modules, imported as `wgpathd.<module>`. |
| `/usr/share/ucode/wgpathd/components/*.uc` | 0644 | I/O components: command runner, ICMP prober, HTTP client, clock. |
| `/etc/config/wgpathd` | 0600 | UCI configuration; a conffile, kept on upgrade. See [UCI configuration](uci-config.md). |
| `/etc/init.d/wgpathd` | 0755 | procd init script. See [below](#etcinitdwgpathd). |
| `/usr/share/nftables.d/chain-pre/input/wgpathd.nft` | 0644 | fw4 include. See [Firewall rules](firewall.md). |
| `/usr/share/rpcd/ucode/wgpathd.uc` | 0644 | rpcd plugin serving the `wgpathd.config` ubus object. See [ubus config check](ubus-config-check.md). |

Nothing is installed on the `PATH`. The scripts in `/usr/libexec/wgpathd/` are ucode scripts, meant to be run through the init script; see [Service commands](service-commands.md).

## Runtime files

| Path | Description |
| :--- | :--- |
| `/var/run/wgpathd/cache.json` | Spoke only. The last valid discovery payload, as JSON. Written through `cache.json.tmp` and a rename after each successful fetch; read and re-validated at startup. On tmpfs, so it survives a restart of the daemon but not a reboot. An unreadable or invalid file is treated as empty. |

wgpathd writes no other files. It never writes `/etc/config`.

## `/etc/init.d/wgpathd`

A procd service with `START=95` and `STOP=10`. When `option enabled` is on and the configuration passes `check.uc --config`, it runs one instance, named `wgpathd`, with:

| Setting | Value | Effect |
| :--- | :--- | :--- |
| `command` | `/usr/libexec/wgpathd/daemon.uc` | Runs the daemon. |
| `respawn` | `3600 5 0` | Restarts the daemon 5 seconds after it exits, with no retry limit. |
| `watchdog` | `1 30` | Passive watchdog: procd restarts the instance if it has not been pinged for 30 seconds. The daemon pings at the end of every cycle. |
| `stderr` | `1` | Standard error goes to the system log, under `daemon.uc[<PID>]`. The daemon's messages go to syslog directly, so this only catches an uncaught exception. |

| Trigger | Effect |
| :--- | :--- |
| `config.change` for `wgpathd` | `reload` |
| `config.change` for `network` | `reload` |

The script adds the `check` command and replaces `reload` and `status`. What each command does is in [Service commands](service-commands.md).

## Package scripts

| Script | Effect |
| :--- | :--- |
| post-install (install and upgrade) | OpenWrt's default first: on a first install, enable the service; on both, run `start`, which does nothing while `enabled` is `0` or the daemon is already running. Then `/etc/init.d/firewall reload` and `/etc/init.d/rpcd reload`, and on an upgrade, restart the daemon if it is running so the new code takes over. |
| post-remove | `/etc/init.d/firewall reload` and `/etc/init.d/rpcd reload`. |

The rpcd reload makes rpcd load the `wgpathd.config` plugin, or drop it after removal, and pick up new module code after an upgrade. rpcd re-executes itself and keeps its sessions, so LuCI users stay logged in.

Both reloads are skipped when the package is installed into a firmware image rather than on a running router.

## Dependencies

| Package | Used for |
| :--- | :--- |
| `ucode` | The interpreter |
| `ucode-mod-uloop` | Event loop, timers, the `wg set` process |
| `ucode-mod-fs` | Discovery cache |
| `ucode-mod-ubus` | `wireguard status`, status object, watchdog ping |
| `ucode-mod-uci` | Configuration |
| `ucode-mod-log` | syslog |
| `ucode-mod-socket` | Spoke probes (raw ICMP and ICMPv6 sockets), hub discovery listener |
| `ucode-mod-rtnl` | Relay route lookup, the MTU of `mesh_iface` |
| `ucode-mod-uclient` | Spoke discovery fetch |
| `rpcd-mod-wireguard` | The `wireguard status` ubus method |
| `rpcd-mod-ucode` | Runs the `wgpathd.config` plugin inside rpcd |
| `wireguard-tools` | `wg set` |
| `kmod-wireguard` | WireGuard in the kernel |

The probes need no command: the daemon sends them itself on raw sockets, which needs root, as procd runs it.

---

## `luci-app-wgpathd`

The LuCI pages for wgpathd are a second package, `luci-app-wgpathd`, built from the same source with the same version and release, architecture `all`, license MIT: `luci-app-wgpathd-0.1.0-r3.apk`. It is optional; the daemon does not need it.

### Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/www/luci-static/resources/view/wgpathd/status.js` | 0644 | The **Status → Mesh paths** page. |
| `/www/luci-static/resources/view/wgpathd/settings.js` | 0644 | The **Network → Mesh paths** page. |
| `/usr/share/luci/menu.d/luci-app-wgpathd.json` | 0644 | The two menu entries, `admin/status/wgpathd` and `admin/network/wgpathd`. Each is shown only to a session granted the `luci-app-wgpathd` ACL, and only while `/etc/config/wgpathd` exists. |
| `/usr/share/rpcd/acl.d/luci-app-wgpathd.json` | 0644 | The `luci-app-wgpathd` ACL; see below. |

### ACL

| Access | Grants |
| :--- | :--- |
| read | ubus `wgpathd` `status`; ubus `wgpathd.config` `check`; UCI `wgpathd` and `network` |
| write | UCI `wgpathd` and `network` |

`network` is included because a peer's wgpathd settings are the `wgpathd_relay` and `wgpathd_tunnel` options of its `wireguard_<mesh_iface>` section; see [Substrate annotations](substrate.md#options-read-per-peer).

### Package scripts

| Script | Effect |
| :--- | :--- |
| post-install (install and upgrade) | OpenWrt's default first, then the same as LuCI's own applications: delete LuCI's menu and module caches (`/tmp/luci-indexcache.*`, `/tmp/luci-modulecache/`) so the new menu entries appear, and `/etc/init.d/rpcd reload` so rpcd reads the new ACL. |
| post-remove | The same cache deletion and `rpcd` reload. |

Both are skipped when the package is installed into a firmware image rather than on a running router.

### Dependencies

| Package | Used for |
| :--- | :--- |
| `luci-base` | LuCI itself |
| `wgpathd`, exactly the same version and release (`wgpathd=0.1.0-r3`) | The ubus objects and the configuration the pages read and write. apk refuses to install the app next to any other wgpathd release, and keeps the daemon while the app is installed. |
