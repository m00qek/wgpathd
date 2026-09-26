# How to Remove wgpathd

Removing wgpathd leaves your WireGuard interfaces as they are, including whatever endpoint it last set on each mesh peer.

---

## 1. Decide where the peers should be left

When wgpathd stops, each mesh peer keeps its last endpoint until something changes it. A peer left on a direct endpoint keeps working only while that direct path does; nothing will fall back to the relay any more.

To leave every managed peer on the relay first, switch the spoke to observe and let it run for one cycle:

```bash
uci set wgpathd.main.mode='observe'
uci commit wgpathd
service wgpathd restart
sleep 5
```

## 2. Stop and remove the package

```bash
service wgpathd stop
service wgpathd disable
apk del wgpathd
```

## 3. Reload the firewall

The fw4 include is removed with the package, but the rules stay loaded until the next reload:

```bash
service firewall reload
```

## 4. Clean up leftovers

Remove the runtime cache on a spoke:

```bash
rm -rf /var/run/wgpathd
```

If `/etc/config/wgpathd` is still there after removal, delete it.

The `wgpathd_relay` and `wgpathd_tunnel` options in `/etc/config/network` are ignored by netifd and can stay. Remove them if you want a clean file.

## Afterwards

Mesh peers without an endpoint in `/etc/config/network` get none after the next `service network reload` or reboot, so spoke-to-spoke traffic over `wg_mesh` stops until you give them one. Set a static `endpoint_host` and `endpoint_port` on those peers if you want them to keep working without wgpathd.
