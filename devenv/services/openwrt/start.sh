#!/bin/sh
set -e
# Bring up procd, apply role config, start wgpathd. SKELETON.
/usr/local/bin/setup-uci.sh
exec /sbin/init
