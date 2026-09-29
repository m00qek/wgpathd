# Files and Dependencies

The package is `wgpathd`, version `0.1.0`, release `6`, architecture `all`, license MIT. It is built as `wgpathd-0.1.0-r6.apk`.

---

## Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/usr/libexec/wgpathd/daemon.uc` | 0755 | The daemon, run by procd. |
| `/usr/libexec/wgpathd/status.uc` | 0755 | Prints the running daemon's status as text, for `service wgpathd status`. |
| `/usr/libexec/wgpathd/check.uc` | 0755 | The validator behind `service wgpathd check`; with `--config`, the check that `start` and `reload` run. |
| `/usr/libexec/wgpathd/migrate.uc` | 0755 | Moves the peer settings of releases up to 4 out of `/etc/config/network`, for `service wgpathd migrate` and the uci-defaults script below. |
| `/etc/uci-defaults/50-wgpathd-peers` | 0755 | Runs `migrate.uc` once; see [below](#etcuci-defaults50-wgpathd-peers). |
| `/usr/share/ucode/wgpathd/*.uc` | 0644 | The ucode modules, imported as `wgpathd.<module>`. |
| `/usr/share/ucode/wgpathd/components/*.uc` | 0644 | I/O components: command runner, ICMP prober, HTTP client, clock. |
| `/etc/config/wgpathd` | 0600 | UCI configuration; a conffile, kept on upgrade. See [UCI configuration](uci-config.md). |
| `/etc/init.d/wgpathd` | 0755 | procd init script. See [below](#etcinitdwgpathd). |
| `/usr/share/rpcd/ucode/wgpathd.uc` | 0644 | rpcd plugin serving the `wgpathd.config` ubus object. See [ubus config check](ubus-config-check.md). |

Nothing is installed on the `PATH`, and no firewall rule: the operator adds what wgpathd needs, see [Firewall rules](firewall.md). The scripts in `/usr/libexec/wgpathd/` are ucode scripts, meant to be run through the init script; see [Service commands](service-commands.md).

## Runtime files

| Path | Description |
| :--- | :--- |
| `/var/run/wgpathd/cache.json` | Spoke only. The last valid discovery payload, as JSON. Written through `cache.json.tmp` and a rename after each successful fetch; read and re-validated at startup. On tmpfs, so it survives a restart of the daemon but not a reboot. An unreadable or invalid file is treated as empty. The directory is set to mode `0700` and the file to `0600`, whatever the umask. wgpathd neither writes nor reads the cache when `/var/run/wgpathd` is not a directory owned by root, or others may write to it. It does not read a `cache.json` that is not a regular file, and does not write when `cache.json.tmp` is a symbolic link; the temporary file is always created anew. |

The daemon writes no other files, and never writes `/etc/config`. Only the migration does, as described below.

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

The script adds the `check` and `migrate` commands and replaces `reload` and `status`. What each command does is in [Service commands](service-commands.md).

## `/etc/uci-defaults/50-wgpathd-peers`

A uci-defaults script: OpenWrt runs it once, then deletes it. It runs `/usr/libexec/wgpathd/migrate.uc`, which moves the options `wgpathd_relay` and `wgpathd_tunnel` of every `wireguard_*` section in `/etc/config/network` into the [`peer` section](uci-config.md#peer-sections) with that section's `public_key` in `/etc/config/wgpathd`, as `relay` and `tunnel`:

- It adds a `peer` section only for a key that has none, and never replaces a value the section already holds. A value it does not take is logged, and dropped from network all the same.
- It commits `/etc/config/wgpathd` first, and only then deletes the two options from `/etc/config/network` and commits it. It writes no copy of either file.
- A section without a valid `public_key` cannot be keyed: its options stay, and are logged.
- With nothing to move it changes nothing and exits 0.
- When a step fails, `/etc/config/network` is left as it was and the script exits non-zero, so OpenWrt keeps it and runs it again at the next boot.

It runs on a first install and on every upgrade, from the package's post-install script (below), and at boot while it is still there. Its log lines start with `migrate:`; see [Log messages](log-messages.md#migration). `service wgpathd migrate` runs the same program by hand. [How to upgrade from a release that kept peer settings in the network configuration](../how-to/upgrade-peer-settings.md) shows how to check it.

## Package scripts

| Script | Effect |
| :--- | :--- |
| post-install (install and upgrade) | OpenWrt's default first: run the package's uci-defaults script, which moves peer settings left in `/etc/config/network`; on a first install, enable the service; on both, run `start`, which does nothing while `enabled` is `0` or the daemon is already running. Then `/etc/init.d/rpcd reload`; `/etc/init.d/firewall reload` when rules with a `wgpathd:` comment are loaded, which only a release up to 5 left, whose include the upgrade has just removed; and on an upgrade, restart the daemon if it is running so the new code takes over. The migration has run by then, so the restarted daemon reads the moved settings. |
| post-remove | `/etc/init.d/rpcd reload`. |

The rpcd reload makes rpcd load the `wgpathd.config` plugin, or drop it after removal, and pick up new module code after an upgrade. rpcd re-executes itself and keeps its sessions, so LuCI users stay logged in.

The reloads and the restart are skipped when the package is installed into a firmware image rather than on a running router.

## Dependencies

| Package | Used for |
| :--- | :--- |
| `ucode` | The interpreter |
| `ucode-mod-uloop` | Event loop, timers, the `wg set` process |
| `ucode-mod-fs` | Discovery cache, random bytes for the probes (`/dev/urandom`) |
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

The LuCI pages for wgpathd are a second package, `luci-app-wgpathd`, built from the same source with the same version and release, architecture `all`, license MIT: `luci-app-wgpathd-0.1.0-r6.apk`. It is optional; the daemon does not need it.

### Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/www/luci-static/resources/view/wgpathd/status.js` | 0644 | The **Status → Mesh paths** page. |
| `/www/luci-static/resources/view/wgpathd/settings.js` | 0644 | The **Network → Mesh paths** page. |
| `/www/luci-static/resources/wgpathd.js` | 0644 | Shared by the pages and the Overview section (`'require wgpathd'`): the `status` call, the path strip, and the words for states, times and reasons. |
| `/www/luci-static/resources/view/status/include/70_wgpathd.js` | 0644 | The **Mesh paths** section of **Status → Overview**. Hidden while the service is not running, on a hub, and when no peer is steered. |
| `/usr/share/luci/menu.d/luci-app-wgpathd.json` | 0644 | The two menu entries, `admin/status/wgpathd` and `admin/network/wgpathd`. Each is shown only to a session granted the `luci-app-wgpathd` ACL, and only while `/etc/config/wgpathd` exists. |
| `/usr/share/rpcd/acl.d/luci-app-wgpathd.json` | 0644 | The `luci-app-wgpathd` ACL; see below. |

### ACL

| Access | Grants |
| :--- | :--- |
| read | ubus `wgpathd` `status`; ubus `wgpathd.config` `check`, `peers` and `schema`; UCI `wgpathd` |
| write | UCI `wgpathd` |

It grants nothing of `/etc/config/network`, which holds every WireGuard private key of the router, nor of `/etc/config/firewall`, which the configuration check reads inside rpcd. The pages name the peers through the [`peers` method](ubus-config-check.md#peers), which returns each peer's section name, public key and description and nothing else, and a peer's settings are [`peer` sections](uci-config.md#peer-sections) of `/etc/config/wgpathd`.

The pages also read the router's host name and time zone from UCI `system`, which the `luci-base` ACL already grants: the name labels this router in the path strip, and the time zone sets the clock times of recent changes, as in the system log. Without it they show "This router" and UTC.

### Package scripts

| Script | Effect |
| :--- | :--- |
| post-install (install and upgrade) | OpenWrt's default first, then the same as LuCI's own applications: delete LuCI's menu and module caches (`/tmp/luci-indexcache.*`, `/tmp/luci-modulecache/`) so the new menu entries appear, and `/etc/init.d/rpcd reload` so rpcd reads the new ACL. |
| post-remove | The same cache deletion and `rpcd` reload. |

Both are skipped when the package is installed into a firmware image rather than on a running router.

### Dependencies

| Package | Used for |
| :--- | :--- |
| `luci-base` | LuCI itself, and read access to UCI `system` |
| `wgpathd`, exactly the same version and release (`wgpathd=0.1.0-r6`) | The ubus objects and the configuration the pages read and write. apk refuses to install the app next to any other wgpathd release, and keeps the daemon while the app is installed. |
