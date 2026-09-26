#!/bin/sh
# Runs inside the openwrt container.
cd "$(dirname "$0")/../.."
status=0

for f in $(find src test -name '*.uc') files/usr/sbin/wgpathd; do
	ucode -L "$PWD/src" -c -o /dev/null "$f" || { echo "  in $f" >&2; status=1; }
done

for f in files/etc/init.d/wgpathd files/etc/uci-defaults/* devenv/scripts/*.sh devenv/services/openwrt/*.sh; do
	sh -n "$f" || { echo "  in $f" >&2; status=1; }
done

exit $status
