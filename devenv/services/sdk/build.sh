#!/bin/sh
# Runs inside the sdk container, with the package sources mounted under
# package/wgpathd and the output directory at /artifacts.
set -e
cd /sdk

make defconfig >/dev/null 2>&1
# NO_DEPS: both packages are ucode and JavaScript, so their runtime DEPENDS need
# not be compiled to package them; only their metadata (from the feeds) is used.
make package/wgpathd/compile NO_DEPS=1 CHECK_KEY=0 ${VERBOSE:+V=s}

find bin/ \( -name 'wgpathd-*.apk' -o -name 'luci-app-wgpathd-*.apk' \) -exec cp -v {} /artifacts/ \;
