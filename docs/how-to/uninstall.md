# How to Remove wgpathd

Removing wgpathd leaves your WireGuard interfaces as they are, including whatever endpoint it last set on each mesh peer.

---

## 1. Decide where the peers should be left

When wgpathd stops, each mesh peer keeps its last endpoint until something changes it. A peer left on a direct endpoint keeps working only while that direct path does; nothing will fall back to the relay any more.

To leave every managed peer on the relay first, switch the spoke to observe and let it run for one cycle:

```bash
uci set wgpathd.main.mode='observe'
uci commit wgpathd
service wgpathd reload
sleep 5
```

## 2. Remove the package

```bash
apk del wgpathd
```

Removing the package stops and disables the service, reloads the firewall, which drops the `wgpathd:` rules, and reloads rpcd, which drops the `wgpathd.config` ubus object.

## 3. Clean up leftovers

Remove the runtime cache on a spoke:

```bash
rm -rf /var/run/wgpathd
```

If `/etc/config/wgpathd` is still there after removal, delete it.

wgpathd keeps nothing in `/etc/config/network`. If the router ran a release up to 4 and its settings were never moved, the `wgpathd_relay` and `wgpathd_tunnel` options may still be there: netifd ignores them, so they can stay, or you can remove them for a clean file.

## Afterwards

Mesh peers without an endpoint in `/etc/config/network` get none after the next `service network reload` or reboot, so spoke-to-spoke traffic over `wg_mesh` stops until you give them one. Set a static `endpoint_host` and `endpoint_port` on those peers if you want them to keep working without wgpathd.
