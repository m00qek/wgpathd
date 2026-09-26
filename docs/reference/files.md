# Files and Dependencies

The package is `wgpathd`, version `0.1.0`, release `1`, architecture `all`, license MIT. It is built as `wgpathd-0.1.0-r1.apk`.

---

## Installed files

| Path | Mode | Description |
| :--- | :--- | :--- |
| `/usr/sbin/wgpathd` | 0755 | The executable. See [below](#usrsbinwgpathd). |
| `/usr/share/ucode/wgpathd/*.uc` | 0644 | The ucode modules, imported as `wgpathd.<module>`. |
| `/usr/share/ucode/wgpathd/components/*.uc` | 0644 | I/O components: command runner, HTTP client, clock. |
| `/etc/config/wgpathd` | 0600 | UCI configuration; a conffile, kept on upgrade. See [UCI configuration](uci-config.md). |
| `/etc/init.d/wgpathd` | 0755 | procd init script. See [below](#etcinitdwgpathd). |
| `/etc/uci-defaults/10-wgpathd-setup` | 0755 | First-install hook. It does nothing and is deleted after it runs on install. |
| `/usr/share/nftables.d/chain-pre/input/wgpathd.nft` | 0644 | fw4 include. See [Firewall rules](firewall.md). |

## Runtime files

| Path | Description |
| :--- | :--- |
| `/var/run/wgpathd/cache.json` | Spoke only. The last valid discovery payload, as JSON. Written through `cache.json.tmp` and a rename after each successful fetch; read and re-validated at startup. On tmpfs, so it survives a restart of the daemon but not a reboot. An unreadable or invalid file is treated as empty. |

wgpathd writes no other files. It never writes `/etc/config`.

## `/usr/sbin/wgpathd`

```
wgpathd           run the daemon in the foreground
wgpathd status    print the running daemon's ubus status as indented JSON
```

| Invocation | Exit status |
| :--- | :--- |
| `wgpathd` | `0` after a normal stop; `1` on an invalid configuration or failed startup |
| `wgpathd status` | `0` on success; `1` if the status cannot be read, with `wgpathd status: <CODE>` on standard error |
| anything else | `2`, with `usage: wgpathd [status]` on standard error |

`wgpathd status` returns the same data as [`ubus call wgpathd status`](ubus-status.md).

## `/etc/init.d/wgpathd`

A procd service with `START=95` and `STOP=10`. It runs one instance, named `wgpathd`, with:

| Setting | Value | Effect |
| :--- | :--- | :--- |
| `command` | `/usr/sbin/wgpathd` | Runs the daemon. |
| `respawn` | `3600 5 0` | Restarts the daemon 5 seconds after it exits, with no retry limit. |
| `watchdog` | `1 30` | Passive watchdog: procd restarts the instance if it has not been pinged for 30 seconds. The daemon pings at the end of every cycle. |
| `stderr` | `1` | Standard error goes to the system log. |

The script defines no reload triggers. Changes to `/etc/config/wgpathd` or `/etc/config/network` take effect after `service wgpathd restart`.

On install, OpenWrt's package scripts enable the service and start it with whatever configuration is present.

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
