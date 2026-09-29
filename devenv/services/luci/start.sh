#!/bin/sh
# Runs as the LuCI container's command, with no network but loopback. Installs the
# built packages offline, then starts ubusd, rpcd, uhttpd and the fakes of wgpathd
# and of procd's `system` object by hand (nothing here boots procd), and stays in the
# foreground while they run.
set -eu

: "${PKG_FULLVERSION:?run through make browser}"

# The postinst scripts reload services through procd, which is not running.
apk add --allow-untrusted --no-network \
	"/artifacts/wgpathd-$PKG_FULLVERSION.apk" "/artifacts/luci-app-wgpathd-$PKG_FULLVERSION.apk" >/tmp/install.log 2>&1 ||
	{ cat /tmp/install.log >&2; exit 1; }

touch /etc/config/network /etc/config/system
uci batch </fixtures/router.uci
printf 'admin\nadmin\n' | passwd root >/dev/null 2>&1
cp /opt/luci/acl.json /usr/share/rpcd/acl.d/wgpathd-browser-tests.json

mkdir -p /var/run/ubus /var/lock
ubusd &
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S /var/run/ubus/ubus.sock ] && break; sleep 1; done
rpcd &
ubus -t 10 wait_for session uci

ucode /opt/luci/fake-system.uc &
FIXTURES=/fixtures ucode /opt/luci/fake-wgpathd.uc &
ubus -t 10 wait_for system wgpathd.fixture

# The flags /etc/init.d/uhttpd derives from the shipped config, on loopback only.
uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -t 60 -T 30 -k 20 -A 1 -n 3 -N 100 -p 127.0.0.1:80 &

echo "luci ready"
wait
