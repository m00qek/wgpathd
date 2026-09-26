#!/bin/sh
# Runs inside the sdk container, with the package sources mounted under
# package/wgpathd and the output directory at /artifacts.
set -e
cd /sdk

make defconfig >/dev/null 2>&1
# NO_DEPS: wgpathd is pure ucode, so its runtime DEPENDS need not be compiled
# to package it; only their metadata (from the feeds) is used.
make package/wgpathd/compile NO_DEPS=1 CHECK_KEY=0 ${VERBOSE:+V=s}

find bin/ -name 'wgpathd-*.apk' -exec cp -v {} /artifacts/ \;
