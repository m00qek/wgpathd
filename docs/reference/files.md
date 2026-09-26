# Files and Dependencies

The package is `wgpathd`, version `0.1.0`, release `1`, architecture `all`, license MIT. It is built as `wgpathd-0.1.0-r1.apk`.

---

## Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/usr/libexec/wgpathd/daemon.uc` | 0755 | The daemon, run by procd. |
| `/usr/libexec/wgpathd/status.uc` | 0755 | Prints the running daemon's status as text, for `service wgpathd status`. |
| `/usr/libexec/wgpathd/check.uc` | 0755 | The validator behind `service wgpathd check`; with `--config`, the check that `start` and `reload` run. |
| `/usr/share/ucode/wgpathd/*.uc` | 0644 | The ucode modules, imported as `wgpathd.<module>`. |
| `/usr/share/ucode/wgpathd/components/*.uc` | 0644 | I/O components: command runner, HTTP client, clock. |
| `/etc/config/wgpathd` | 0600 | UCI configuration; a conffile, kept on upgrade. See [UCI configuration](uci-config.md). |
| `/etc/init.d/wgpathd` | 0755 | procd init script. See [below](#etcinitdwgpathd). |
| `/usr/share/nftables.d/chain-pre/input/wgpathd.nft` | 0644 | fw4 include. See [Firewall rules](firewall.md). |

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
| `stderr` | `1` | Standard error goes to the system log. |

| Trigger | Effect |
| :--- | :--- |
| `config.change` for `wgpathd` | `reload` |
| `config.change` for `network` | `reload` |

The script adds the `check` command and replaces `reload` and `status`. What each command does is in [Service commands](service-commands.md).

## Package scripts

| Script | Effect |
| :--- | :--- |
| post-install (install and upgrade) | `/etc/init.d/firewall reload`, then OpenWrt's default: on a first install, enable the service; on both, run `start`. `start` does nothing while `enabled` is `0`, and does not restart a daemon that is already running. |
| post-remove | `/etc/init.d/firewall reload`. |

The firewall reload is skipped when the package is installed into a firmware image rather than on a running router.

## Dependencies

| Package | Used for |
| :--- | :--- |
| `ucode` | The interpreter |
| `ucode-mod-uloop` | Event loop, timers, child processes |
| `ucode-mod-fs` | Discovery cache |
| `ucode-mod-ubus` | `wireguard status`, status object, watchdog ping |
| `ucode-mod-uci` | Configuration |
| `ucode-mod-log` | syslog |
| `ucode-mod-socket` | Hub discovery listener |
| `ucode-mod-rtnl` | Relay route lookup |
| `ucode-mod-uclient` | Spoke discovery fetch |
| `rpcd-mod-wireguard` | The `wireguard status` ubus method |
| `wireguard-tools` | `wg set` |
| `kmod-wireguard` | WireGuard in the kernel |

The probes use busybox `ping`, which must support `-6`, `-c` and `-W`; the OpenWrt default busybox does.
