#!/bin/sh
# Installs the built .apk into a pristine rootfs container and checks what a
# plain one-shot container can show. Nothing here boots procd or ubusd, so
# service start/stop and the daemon's ubus object are out of reach.
set -u

APK=$(ls /artifacts/wgpathd-*.apk 2>/dev/null | head -n1)
failures=0
exec 3>&1

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

has_mode() { [ -n "$(find "$2" -prune -perm "$1")" ]; }

# A ucode exception prints "Runtime error" / "Syntax error" and a stack of
# "In ..., file ..., line ..." frames; a clean failure prints one reason.
fails_cleanly() {
	out=$("$@" 2>&1) && return 1
	[ -n "$out" ] || return 1
	echo "$out" | grep -qE 'Runtime error|Syntax error|called from|^In ' && return 1
	echo "     -> $out" >&3
}

[ -n "$APK" ] || { echo "no wgpathd-*.apk in /artifacts (run make package)" >&2; exit 1; }
echo "checking $APK"

mkdir -p /var/lock
apk update >/dev/null 2>&1 || { echo "apk update failed" >&2; exit 1; }

check "dependencies resolve" apk add --allow-untrusted --simulate "$APK"
# No module load attempts against the host kernel from kmod-wireguard's scripts.
check "kmod-wireguard installs (scripts skipped)" apk add --no-scripts kmod-wireguard
check "package installs" apk add --allow-untrusted "$APK"

check "config 0600"         has_mode 600 /etc/config/wgpathd
check "init script 0755"    has_mode 755 /etc/init.d/wgpathd
check "wgpathd binary 0755" has_mode 755 /usr/sbin/wgpathd
check "fw4 include 0644"    has_mode 644 /usr/share/nftables.d/chain-pre/input/wgpathd.nft
check "modules 0644"        has_mode 644 /usr/share/ucode/wgpathd/daemon.uc
check "components shipped"  test -f /usr/share/ucode/wgpathd/components/exec.uc
check "uci-defaults shipped" grep -qx /etc/uci-defaults/10-wgpathd-setup /lib/apk/packages/wgpathd.list
check "uci-defaults consumed on install" test ! -e /etc/uci-defaults/10-wgpathd-setup
check "config is a conffile" grep -qx /etc/config/wgpathd /lib/apk/packages/wgpathd.conffiles

check "modules on default search path" ucode -e 'import * as d from "wgpathd.daemon"; exit(type(d.run) == "function" ? 0 : 1);'
check "daemon with default config fails cleanly" fails_cleanly /usr/sbin/wgpathd
check "status without a daemon fails cleanly" fails_cleanly /usr/sbin/wgpathd status

/etc/init.d/wgpathd disable
check "init script enables" sh -c '/etc/init.d/wgpathd enable && [ -L /etc/rc.d/S95wgpathd ]'

check "fw4 includes the nft file" sh -c \
	'fw4 print 2>/dev/null | grep -q "include \"/usr/share/nftables.d/chain-pre/input/wgpathd.nft\""'

[ "$failures" -eq 0 ] && echo "package-check: all passed" && exit 0
echo "package-check: $failures failed"
exit 1
